//
//  DevServerManager.swift
//  AgentHub
//
//  Manages dev server lifecycle: project detection, process spawning,
//  readiness monitoring, and cleanup.
//

import Foundation

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

  // MARK: - Public API

  /// Returns the current state for a project, or `.idle` if none
  public func state(for projectPath: String) -> DevServerState {
    servers[projectPath] ?? .idle
  }

  /// Starts a dev server for the given project path.
  /// Idempotent: if already running or ready, returns immediately.
  public func startServer(for projectPath: String) async {
    // Guard: already in an active state
    switch servers[projectPath] {
    case .ready, .starting, .waitingForReady, .detecting:
      return
    default:
      break
    }

    servers[projectPath] = .detecting

    // 1. Detect project type (off main thread for file I/O)
    let detected = await Task.detached { [projectPath] in
      DevServerManager.detectProject(at: projectPath)
    }.value

    // 2. Find executable
    let command = detected.command
    let executablePath = await Task.detached {
      TerminalLauncher.findExecutable(command: command, additionalPaths: nil)
    }.value

    guard let executablePath else {
      servers[projectPath] = .failed(
        error: "Could not find '\(detected.command)'. Make sure it's installed and in your PATH."
      )
      return
    }

    // 3. Find available port
    let port = await Task.detached {
      DevServerManager.findAvailablePort(preferring: detected.defaultPort)
    }.value

    assignedPorts[projectPath] = port

    AppLogger.devServer.info(
      "Starting \(detected.framework.rawValue) server at \(projectPath) on port \(port)"
    )

    servers[projectPath] = .starting(
      message: "Starting \(detected.framework.rawValue) dev server..."
    )

    // 4. Spawn process
    do {
      let process = try spawnServerProcess(
        executablePath: executablePath,
        detected: detected,
        projectPath: projectPath,
        port: port
      )

      processes[projectPath] = process
      TerminalProcessRegistry.shared.register(pid: process.processIdentifier)

      servers[projectPath] = .waitingForReady

      // 5. Monitor for readiness
      readinessTasks[projectPath] = Task { [weak self] in
        await self?.monitorForReadiness(
          projectPath: projectPath,
          process: process,
          port: port,
          patterns: detected.readinessPatterns
        )
      }
    } catch {
      servers[projectPath] = .failed(error: error.localizedDescription)
    }
  }

  /// Stops the server for a given project path.
  public func stopServer(for projectPath: String) {
    readinessTasks[projectPath]?.cancel()
    readinessTasks.removeValue(forKey: projectPath)

    // Clean up pipe handlers
    if let pipes = outputPipes[projectPath] {
      pipes.stdout.fileHandleForReading.readabilityHandler = nil
      pipes.stderr.fileHandleForReading.readabilityHandler = nil
    }
    outputPipes.removeValue(forKey: projectPath)

    guard let process = processes[projectPath] else {
      servers[projectPath] = .idle
      return
    }

    servers[projectPath] = .stopping
    let pid = process.processIdentifier

    AppLogger.devServer.info("Stopping server for \(projectPath) (PID: \(pid))")

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
    processes.removeValue(forKey: projectPath)
    assignedPorts.removeValue(forKey: projectPath)
    servers[projectPath] = .idle
  }

  /// Stops all running servers. Called on app quit.
  public func stopAllServers() {
    for projectPath in Array(processes.keys) {
      stopServer(for: projectPath)
    }
  }

  // MARK: - Project Detection

  /// Detects the project framework from package.json and returns the appropriate server config.
  /// Uses shared `ProjectFramework.detect(at:)` for framework identification, then maps to
  /// the full `DetectedProject` with command, args, port, and readiness patterns.
  private nonisolated static func detectProject(at projectPath: String) -> DetectedProject {
    let framework = ProjectFramework.detect(at: projectPath)

    switch framework {
    case .vite:
      return DetectedProject(
        framework: .vite,
        command: "npm",
        arguments: ["run", "dev", "--", "--port"],
        defaultPort: 5173,
        readinessPatterns: ["Local:", "localhost:", "ready in", "VITE"]
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
        readinessPatterns: ["localhost:", "astro"]
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
    process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

    // Environment: PATH with NVM/homebrew paths + framework-specific vars
    let homeDir = NSHomeDirectory()
    var environment = ProcessInfo.processInfo.environment
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
    if let existingPath = environment["PATH"] {
      environment["PATH"] = extraPaths.joined(separator: ":") + ":" + existingPath
    } else {
      environment["PATH"] = extraPaths.joined(separator: ":")
    }

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

    outputPipes[projectPath] = (stdoutPipe, stderrPipe)

    // Set up readiness handlers BEFORE starting the process
    // to avoid race conditions with fast-starting servers (e.g. python http.server)
    setupReadinessHandlers(
      projectPath: projectPath,
      port: port,
      patterns: detected.readinessPatterns
    )

    try process.run()
    return process
  }

  // MARK: - Readiness Monitoring

  private func setupReadinessHandlers(
    projectPath: String,
    port: Int,
    patterns: [String]
  ) {
    guard let pipes = outputPipes[projectPath] else { return }

    let handler: @Sendable (FileHandle) -> Void = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      Task { @MainActor [weak self] in
        self?.handleServerOutput(text, projectPath: projectPath, port: port, patterns: patterns)
      }
    }

    pipes.stdout.fileHandleForReading.readabilityHandler = handler
    pipes.stderr.fileHandleForReading.readabilityHandler = handler
  }

  private func monitorForReadiness(
    projectPath: String,
    process: Process,
    port: Int,
    patterns: [String]
  ) async {
    // Process termination handler
    process.terminationHandler = { [weak self] proc in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Only handle if we're still waiting
        switch self.servers[projectPath] {
        case .waitingForReady, .starting:
          self.servers[projectPath] = .failed(
            error: "Server process exited with code \(proc.terminationStatus) before becoming ready."
          )
        default:
          break
        }
      }
    }

    // Timeout: if not ready after 30 seconds, assume ready on expected port
    try? await Task.sleep(for: .seconds(30))

    if case .waitingForReady = servers[projectPath] {
      if process.isRunning {
        AppLogger.devServer.info("Timeout reached, assuming server is ready on port \(port)")
        let url = URL(string: "http://localhost:\(port)")!
        servers[projectPath] = .ready(url: url)
        cleanupPipeHandlers(for: projectPath)
      }
    }
  }

  private func handleServerOutput(
    _ text: String,
    projectPath: String,
    port: Int,
    patterns: [String]
  ) {
    // Only process if still waiting
    guard case .waitingForReady = servers[projectPath] else { return }

    AppLogger.devServer.debug("[\(projectPath)] \(text)")

    let lowered = text.lowercased()
    for pattern in patterns {
      if lowered.contains(pattern.lowercased()) {
        let url = extractURL(from: text) ?? URL(string: "http://localhost:\(port)")!
        AppLogger.devServer.info("Server ready at \(url.absoluteString)")
        servers[projectPath] = .ready(url: url)
        cleanupPipeHandlers(for: projectPath)
        return
      }
    }
  }

  /// Extracts a localhost URL from server output text
  private func extractURL(from text: String) -> URL? {
    let pattern = #"https?://(?:localhost|127\.0\.0\.1):\d+"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text) else {
      return nil
    }
    return URL(string: String(text[range]))
  }

  private func cleanupPipeHandlers(for projectPath: String) {
    if let pipes = outputPipes[projectPath] {
      pipes.stdout.fileHandleForReading.readabilityHandler = nil
      pipes.stderr.fileHandleForReading.readabilityHandler = nil
    }
  }
}
