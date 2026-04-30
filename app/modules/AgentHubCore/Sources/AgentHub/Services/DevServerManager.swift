//
//  DevServerManager.swift
//  AgentHub
//
//  Manages dev server lifecycle: project detection, process spawning,
//  readiness monitoring, and cleanup.
//

import Foundation
import Storybook

// MARK: - DevServerManager

/// Manages dev server processes for web preview.
///
/// Automatically detects project type from `package.json`, starts the appropriate
/// dev server command, monitors output for readiness signals, and provides the
/// localhost URL to the UI. One server per project path, with full lifecycle cleanup.
@MainActor
@Observable
public final class DevServerManager {

  // MARK: - Singleton

  public static let shared = DevServerManager()
  private init() {}

  // MARK: - Observable State

  /// Server state per project path (observed by WebPreviewView)
  private(set) var servers: [String: DevServerState] = [:]

  // MARK: - Internal Tracking

  private var processes: [String: Process] = [:]
  private var outputPipes: [String: (stdout: Pipe, stderr: Pipe)] = [:]
  private var readinessTasks: [String: Task<Void, Never>] = [:]
  private var assignedPorts: [String: Int] = [:]
  private var externalServers: Set<String> = []

  // MARK: - Public API

  /// Returns the current state for a key (session ID or project path), or `.idle` if none
  public func state(for key: String) -> DevServerState {
    servers[key] ?? .idle
  }

  /// Connects the preview to an existing dev server (e.g. one started by the agent).
  /// Does not spawn a process — just points the preview at the given URL.
  public func connectToExistingServer(for key: String, url: URL) {
    guard let normalizedURL = LocalhostURLNormalizer.sanitize(url) else {
      AppLogger.devServer.warning("[DevServerManager] Ignoring invalid agent server URL for key=\(key): \(url.absoluteString)")
      return
    }

    // Don't reconnect if already connected to the same URL
    if case .ready(let existingURL) = servers[key], existingURL == normalizedURL {
      return
    }
    AppLogger.devServer.info("[DevServerManager] Connecting key=\(key) to agent's server at \(normalizedURL.absoluteString)")
    externalServers.insert(key)
    servers[key] = .ready(url: normalizedURL)
  }

  /// Whether the server for this key is an external one (started by the agent, not us)
  public func isExternalServer(for key: String) -> Bool {
    externalServers.contains(key)
  }

  /// Starts a dev server for the given key (typically session ID) at the specified project path.
  /// Idempotent: if already running or ready, returns immediately.
  public func startServer(for key: String, projectPath: String) async {
    await startServer(for: key, projectPath: projectPath, forceFramework: nil)
  }

  /// Internal overload that allows bypassing framework auto-detection (used for Storybook).
  func startServer(for key: String, projectPath: String, forceFramework: ProjectFramework?) async {
    // Guard: already in an active state
    switch servers[key] {
    case .ready, .starting, .waitingForReady, .detecting:
      return
    default:
      break
    }

    servers[key] = .detecting

    // 1. Detect project type (off main thread for file I/O)
    let detected = await Task.detached { [projectPath, forceFramework] in
      if let framework = forceFramework {
        return DevServerManager.detectProject(at: projectPath, framework: framework)
      }
      return DevServerManager.detectProject(at: projectPath)
    }.value

    // 2. Find executable
    let command = detected.command
    let executablePath = await Task.detached {
      TerminalLauncher.findExecutable(command: command, additionalPaths: nil)
    }.value

    guard let executablePath else {
      servers[key] = .failed(
        error: "Could not find '\(detected.command)'. Make sure it's installed and in your PATH."
      )
      return
    }

    // 3. Find available port. We only scan when the args end with a `-p`/`--port`
    // placeholder we can fill — otherwise the dev server's bind port is fixed
    // by its own config (e.g. an npm script that pins `-p 6006`) and scanning
    // would just desync our tracked port from the actual one.
    let canOverridePort = detected.arguments.last == "-p" || detected.arguments.last == "--port"
    let port: Int
    if canOverridePort {
      port = await Task.detached {
        DevServerManager.findAvailablePort(preferring: detected.defaultPort)
      }.value
    } else {
      port = detected.defaultPort
    }

    assignedPorts[key] = port

    AppLogger.devServer.info(
      "[DevServerManager] Starting \(detected.framework.rawValue) server for key=\(key) at \(projectPath) on port \(port)"
    )

    servers[key] = .starting(
      message: "Starting \(detected.framework.rawValue) dev server..."
    )

    // 4. Spawn process
    do {
      let process = try spawnServerProcess(
        key: key,
        executablePath: executablePath,
        detected: detected,
        projectPath: projectPath,
        port: port
      )

      processes[key] = process
      TerminalProcessRegistry.shared.register(pid: process.processIdentifier)

      servers[key] = .waitingForReady

      // 5. Monitor for readiness
      readinessTasks[key] = Task { [weak self] in
        await self?.monitorForReadiness(
          key: key,
          process: process,
          port: port,
          patterns: detected.readinessPatterns
        )
      }
    } catch {
      servers[key] = .failed(error: error.localizedDescription)
    }
  }

  /// Stops the server for a given key (session ID or project path).
  public func stopServer(for key: String) {
    // External servers (started by agent) — just reset state, no process to kill
    if externalServers.contains(key) {
      AppLogger.devServer.info("[DevServerManager] Disconnecting from external server for key=\(key)")
      externalServers.remove(key)
      servers[key] = .idle
      return
    }

    disposeManagedServer(for: key, finalState: .idle, logAction: "Stopping")
  }

  /// Marks a managed server as failed and keeps the error visible to the UI.
  public func failServer(for key: String, error: String) {
    externalServers.remove(key)
    disposeManagedServer(for: key, finalState: .failed(error: error), logAction: "Failing")
  }

  // MARK: - Storybook

  /// Starts a Storybook server alongside the main dev server.
  /// Uses a compound key `"{sessionId}:storybook"` to coexist with the primary server.
  public func startStorybookServer(for sessionId: String, projectPath: String) async {
    let key = "\(sessionId):storybook"
    await startServer(for: key, projectPath: projectPath, forceFramework: .storybook)
  }

  /// Stops the Storybook server for a given session.
  public func stopStorybookServer(for sessionId: String) {
    stopServer(for: "\(sessionId):storybook")
  }

  /// Current state of the Storybook server for a given session.
  public func storybookState(for sessionId: String) -> DevServerState {
    state(for: "\(sessionId):storybook")
  }

  /// Stops all running servers. Called on app quit.
  public func stopAllServers() {
    for key in Array(servers.keys) {
      stopServer(for: key)
    }
  }

  private func disposeManagedServer(
    for key: String,
    finalState: DevServerState,
    logAction: String
  ) {
    readinessTasks[key]?.cancel()
    readinessTasks.removeValue(forKey: key)

    // Clean up pipe handlers
    if let pipes = outputPipes[key] {
      pipes.stdout.fileHandleForReading.readabilityHandler = nil
      pipes.stderr.fileHandleForReading.readabilityHandler = nil
    }
    outputPipes.removeValue(forKey: key)

    guard let process = processes[key] else {
      servers[key] = finalState
      return
    }

    servers[key] = .stopping
    let pid = process.processIdentifier

    AppLogger.devServer.info("[DevServerManager] \(logAction) server for key=\(key) (PID: \(pid))")

    // SIGTERM to process group, then escalate
    if killpg(pid, SIGTERM) != 0 {
      kill(pid, SIGTERM)
    }

    Task.detached {
      try? await Task.sleep(for: .milliseconds(500))
      if process.isRunning {
        if killpg(pid, SIGKILL) != 0 {
          kill(pid, SIGKILL)
        }
      }
    }

    TerminalProcessRegistry.shared.unregister(pid: pid)
    processes.removeValue(forKey: key)
    assignedPorts.removeValue(forKey: key)
    servers[key] = finalState
  }

  // MARK: - Project Detection

  /// Returns a `DetectedProject` for a specific framework, bypassing auto-detection.
  /// Used when the caller already knows the framework (e.g. Storybook launched explicitly).
  nonisolated static func detectProject(at projectPath: String, framework: ProjectFramework) -> DetectedProject {
    mapFrameworkToProject(framework, projectPath: projectPath)
  }

  /// Detects the project framework from package.json and returns the appropriate server config.
  /// Uses shared `ProjectFramework.detect(at:)` for framework identification, then maps to
  /// the full `DetectedProject` with command, args, port, and readiness patterns.
  nonisolated static func detectProject(at projectPath: String) -> DetectedProject {
    let framework = ProjectFramework.detect(at: projectPath)
    return mapFrameworkToProject(framework, projectPath: projectPath)
  }

  private nonisolated static func mapFrameworkToProject(_ framework: ProjectFramework, projectPath: String) -> DetectedProject {
    switch framework {
    case .vite:
      return DetectedProject(
        framework: .vite,
        command: "npm",
        arguments: ["run", "dev", "--", "--port"],
        defaultPort: 5173,
        // Avoid matching npm's echoed command line (`vite --port ...`) before
        // the dev server has actually bound the socket.
        readinessPatterns: ["Local:", "localhost:", "ready in"]
      )
    case .nextjs:
      return DetectedProject(
        framework: .nextjs,
        command: "npm",
        arguments: ["run", "dev", "--", "-p"],
        defaultPort: 3000,
        readinessPatterns: ["Ready in", "started server", "localhost:"]
      )
    case .createReactApp:
      return DetectedProject(
        framework: .createReactApp,
        command: "npm",
        arguments: ["start"],
        defaultPort: 3000,
        readinessPatterns: ["Compiled successfully", "localhost:"]
      )
    case .angular:
      return DetectedProject(
        framework: .angular,
        command: "npm",
        arguments: ["start", "--", "--port"],
        defaultPort: 4200,
        readinessPatterns: ["Angular Live Development Server", "localhost:"]
      )
    case .vueCLI:
      return DetectedProject(
        framework: .vueCLI,
        command: "npm",
        arguments: ["run", "serve", "--", "--port"],
        defaultPort: 8080,
        readinessPatterns: ["App running at", "localhost:"]
      )
    case .astro:
      return DetectedProject(
        framework: .astro,
        command: "npm",
        arguments: ["run", "dev", "--", "--port"],
        defaultPort: 4321,
        // Avoid matching npm's echoed command line (`astro dev --port ...`)
        // before Astro prints its real ready banner or localhost URL.
        readinessPatterns: ["ready in", "localhost:"]
      )
    case .storybook:
      let scriptName = StorybookDetector.storybookScript(at: projectPath) ?? "storybook"
      // If the npm script already pins a port (e.g. `storybook dev -p 6006`),
      // honor it — npm appends our extra args AFTER the script's, and storybook
      // only respects the first `-p`, so adding our own would leave the actual
      // bind port out of sync with our tracked port.
      if let scriptPort = StorybookDetector.storybookScriptPort(at: projectPath) {
        return DetectedProject(
          framework: .storybook,
          command: "npm",
          arguments: ["run", scriptName],
          defaultPort: scriptPort,
          readinessPatterns: StorybookDetector.readinessPatterns,
          stdinPrefill: "y\n"
        )
      }
      return DetectedProject(
        framework: .storybook,
        command: "npm",
        arguments: ["run", scriptName, "--", "-p"],
        defaultPort: StorybookDetector.defaultPort,
        readinessPatterns: StorybookDetector.readinessPatterns,
        stdinPrefill: "y\n"
      )
    case .unknown:
      // Has package.json with scripts but no recognized framework
      let fm = FileManager.default
      let packageJsonPath = "\(projectPath)/package.json"
      var scripts: [String: String] = [:]
      if let data = fm.contents(atPath: packageJsonPath),
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        scripts = json["scripts"] as? [String: String] ?? [:]
      }
      if scripts["dev"] != nil {
        return DetectedProject(
          framework: .unknown,
          command: "npm",
          arguments: ["run", "dev"],
          defaultPort: 3000,
          readinessPatterns: ["localhost:", "ready", "compiled", "started", "listening"]
        )
      }
      if scripts["start"] != nil {
        return DetectedProject(
          framework: .unknown,
          command: "npm",
          arguments: ["start"],
          defaultPort: 3000,
          readinessPatterns: ["localhost:", "ready", "compiled", "started", "listening"]
        )
      }
      if scripts["serve"] != nil {
        return DetectedProject(
          framework: .unknown,
          command: "npm",
          arguments: ["run", "serve"],
          defaultPort: 3000,
          readinessPatterns: ["localhost:", "ready", "compiled", "started", "listening"]
        )
      }
      if scripts["preview"] != nil {
        return DetectedProject(
          framework: .unknown,
          command: "npm",
          arguments: ["run", "preview"],
          defaultPort: 4173,
          readinessPatterns: ["localhost:", "ready", "compiled", "started", "listening"]
        )
      }
      return staticHTMLProject()
    case .staticHTML:
      return staticHTMLProject()
    }
  }

  private nonisolated static func staticHTMLProject() -> DetectedProject {
    DetectedProject(
      framework: .staticHTML,
      command: "python3",
      arguments: ["-m", "http.server", "--bind", "127.0.0.1"],
      defaultPort: 8000,
      readinessPatterns: ["Serving HTTP on"]
    )
  }

  // MARK: - Port Management

  /// Finds an available port, preferring the given default
  private nonisolated static func findAvailablePort(preferring preferred: Int) -> Int {
    if isPortAvailable(preferred) { return preferred }
    for port in (preferred + 1)...(preferred + 100) {
      if isPortAvailable(port) { return port }
    }
    return preferred // Fallback: try anyway
  }

  private nonisolated static func isPortAvailable(_ port: Int) -> Bool {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return false }
    defer { close(socketFD) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
  }

  // MARK: - Process Spawning

  private func spawnServerProcess(
    key: String,
    executablePath: String,
    detected: DetectedProject,
    projectPath: String,
    port: Int
  ) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)

    // Build arguments: inject port based on framework conventions
    var args = detected.arguments
    if args.last == "--port" || args.last == "-p" {
      args.append(String(port))
    } else if detected.framework == .staticHTML {
      // python3 -m http.server requires port as positional arg before --bind
      if let bindIndex = args.firstIndex(of: "--bind") {
        args.insert(String(port), at: bindIndex)
      } else {
        args.append(String(port))
      }
    }
    process.arguments = args
    AppLogger.devServer.info("[DevServerManager] Spawning: \(executablePath) \(args.joined(separator: " ")) in \(projectPath)")
    process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

    // Environment: PATH with NVM/homebrew paths + framework-specific vars
    let homeDir = NSHomeDirectory()
    let extraPaths = [
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "\(homeDir)/.nvm/current/bin",
      "\(homeDir)/.nvm/versions/node/v22.16.0/bin",
      "\(homeDir)/.nvm/versions/node/v20.11.1/bin",
      "\(homeDir)/.nvm/versions/node/v18.19.0/bin",
      "\(homeDir)/.bun/bin",
      "/usr/bin"
    ]
    var environment = AgentHubProcessEnvironment.environment(
      additionalPaths: extraPaths,
      workspacePath: projectPath
    )

    // CRA reads PORT env var; BROWSER=none prevents auto-opening
    environment["PORT"] = String(port)
    environment["BROWSER"] = "none"
    process.environment = environment

    // Set up new process group for clean tree termination
    process.qualityOfService = .userInitiated

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Pre-feed stdin for tools that gate on interactive prompts (e.g. Storybook
    // asking to use an alternate port). The bytes sit in the pipe; tools that
    // never call `read()` simply ignore them.
    if let prefill = detected.stdinPrefill, let prefillData = prefill.data(using: .utf8) {
      let stdinPipe = Pipe()
      process.standardInput = stdinPipe
      try? stdinPipe.fileHandleForWriting.write(contentsOf: prefillData)
      try? stdinPipe.fileHandleForWriting.close()
    }

    outputPipes[key] = (stdoutPipe, stderrPipe)

    // Set up readiness handlers BEFORE starting the process
    // to avoid race conditions with fast-starting servers (e.g. python http.server)
    setupReadinessHandlers(
      key: key,
      port: port,
      patterns: detected.readinessPatterns
    )

    try process.run()
    return process
  }

  // MARK: - Readiness Monitoring

  private func setupReadinessHandlers(
    key: String,
    port: Int,
    patterns: [String]
  ) {
    guard let pipes = outputPipes[key] else { return }

    let handler: @Sendable (FileHandle) -> Void = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      Task { @MainActor [weak self] in
        self?.handleServerOutput(text, key: key, port: port, patterns: patterns)
      }
    }

    pipes.stdout.fileHandleForReading.readabilityHandler = handler
    pipes.stderr.fileHandleForReading.readabilityHandler = handler
  }

  private func monitorForReadiness(
    key: String,
    process: Process,
    port: Int,
    patterns: [String]
  ) async {
    // Process termination handler
    process.terminationHandler = { [weak self] proc in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Only handle if we're still waiting
        switch self.servers[key] {
        case .waitingForReady, .starting:
          self.servers[key] = .failed(
            error: "Server process exited with code \(proc.terminationStatus) before becoming ready."
          )
        default:
          break
        }
      }
    }

    // Timeout: if not ready after 30 seconds, assume ready on expected port
    try? await Task.sleep(for: .seconds(30))

    if case .waitingForReady = servers[key] {
      if process.isRunning {
        AppLogger.devServer.info("[DevServerManager] Timeout reached for key=\(key), assuming server is ready on port \(port)")
        let url = URL(string: "http://localhost:\(port)")!
        servers[key] = .ready(url: url)
        cleanupPipeHandlers(for: key)
      }
    }
  }

  private func handleServerOutput(
    _ text: String,
    key: String,
    port: Int,
    patterns: [String]
  ) {
    // Only process if still waiting
    guard case .waitingForReady = servers[key] else { return }

    AppLogger.devServer.debug("[DevServerManager] [\(key)] \(text)")

    let lowered = text.lowercased()
    for pattern in patterns {
      if lowered.contains(pattern.lowercased()) {
        let url = extractURL(from: text) ?? URL(string: "http://localhost:\(port)")!
        AppLogger.devServer.info("[DevServerManager] Server ready for key=\(key) at \(url.absoluteString)")
        servers[key] = .ready(url: url)
        cleanupPipeHandlers(for: key)
        return
      }
    }
  }

  /// Extracts a localhost URL from server output text
  private func extractURL(from text: String) -> URL? {
    LocalhostURLNormalizer.extractFirstURL(from: text)
  }

  private func cleanupPipeHandlers(for key: String) {
    if let pipes = outputPipes[key] {
      pipes.stdout.fileHandleForReading.readabilityHandler = nil
      pipes.stderr.fileHandleForReading.readabilityHandler = nil
    }
  }
}

// MARK: - StorybookService Conformance

extension DevServerManager: StorybookService {
  public func start(for sessionId: String, projectPath: String) async {
    await startStorybookServer(for: sessionId, projectPath: projectPath)
  }

  public func stop(for sessionId: String) {
    stopStorybookServer(for: sessionId)
  }

  public func state(for sessionId: String) -> StorybookServerState {
    let key = "\(sessionId):storybook"
    switch servers[key] {
    case .idle, .detecting, .stopping, nil:
      return .idle
    case .starting, .waitingForReady:
      return .starting
    case .ready(let url):
      return .ready(url: url)
    case .failed(let error):
      return .failed(error: error)
    }
  }
}
