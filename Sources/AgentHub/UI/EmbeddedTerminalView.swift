//
//  EmbeddedTerminalView.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import AppKit
import ClaudeCodeSDK
import SwiftTerm
import SwiftUI

// MARK: - EmbeddedTerminalView

/// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView
/// Provides an embedded terminal for interacting with Claude sessions
public struct EmbeddedTerminalView: NSViewRepresentable {
  let terminalKey: String  // Key for terminal storage (session ID or "pending-{pendingId}")
  let sessionId: String?  // Optional: nil for new sessions, set for resume
  let projectPath: String
  let claudeClient: (any ClaudeCode)?
  let initialPrompt: String?  // Optional: prompt to include with resume command
  let viewModel: CLISessionsViewModel?  // For shared terminal storage

  public init(
    terminalKey: String,
    sessionId: String? = nil,
    projectPath: String,
    claudeClient: (any ClaudeCode)?,
    initialPrompt: String? = nil,
    viewModel: CLISessionsViewModel? = nil
  ) {
    self.terminalKey = terminalKey
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.claudeClient = claudeClient
    self.initialPrompt = initialPrompt
    self.viewModel = viewModel
  }

  public func makeNSView(context: Context) -> TerminalContainerView {
    // Use shared terminal storage if viewModel is provided
    if let viewModel = viewModel {
      return viewModel.getOrCreateTerminal(
        forKey: terminalKey,
        sessionId: sessionId,
        projectPath: projectPath,
        claudeClient: claudeClient,
        initialPrompt: initialPrompt
      )
    }

    // Fallback: create standalone terminal (for previews)
    let containerView = TerminalContainerView()
    containerView.configure(
      sessionId: sessionId,
      projectPath: projectPath,
      claudeClient: claudeClient,
      initialPrompt: initialPrompt
    )
    return containerView
  }

  public func updateNSView(_ nsView: TerminalContainerView, context: Context) {
    // If there's a pending prompt, send it to the existing terminal
    if let prompt = initialPrompt {
      nsView.sendPromptIfNeeded(prompt)
    }
  }
}

// MARK: - TerminalContainerView

/// Container view that manages the terminal lifecycle
public class TerminalContainerView: NSView {
  private var terminalView: LocalProcessTerminalView?
  private var isConfigured = false
  private var promptSent = false  // Track if we've already sent a prompt
  private var shellPid: pid_t = 0  // Track the shell PID for cleanup

  // MARK: - Lifecycle

  /// Terminate process on deallocation (safety net)
  deinit {
    terminateProcess()
  }

  /// Explicitly terminates the terminal process and its children.
  /// Call this before removing the terminal from activeTerminals to ensure cleanup.
  /// Safe to call multiple times - subsequent calls are no-ops.
  public func terminateProcess() {
    // Capture PID locally to avoid race conditions during async work
    let pid = shellPid
    shellPid = 0  // Clear immediately to prevent double-termination

    guard pid > 0 else { return }

    // Check if process is still running (kill with signal 0 just checks existence)
    guard kill(pid, 0) == 0 else { return }

    // Send SIGTERM for graceful shutdown
    if kill(pid, SIGTERM) != 0 {
      AppLogger.session.warning("Failed to send SIGTERM to PID=\(pid), errno=\(errno)")
    }

    // Schedule a follow-up SIGKILL if process doesn't terminate gracefully
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
      // Check if still running
      if kill(pid, 0) == 0 {
        AppLogger.session.warning("Process PID=\(pid) didn't respond to SIGTERM, sending SIGKILL")
        let killResult = kill(pid, SIGKILL)
        if killResult != 0 {
          AppLogger.session.error("Failed to send SIGKILL to PID=\(pid), errno=\(errno)")
        }
      }
    }
  }

  // MARK: - Configuration

  /// Restarts the terminal by terminating the current process and starting a new one.
  /// Use this to reload session history after external changes.
  func restart(
    sessionId: String?,
    projectPath: String,
    claudeClient: (any ClaudeCode)?
  ) {
    terminateProcess()
    terminalView?.removeFromSuperview()
    terminalView = nil
    isConfigured = false
    promptSent = false
    configure(sessionId: sessionId, projectPath: projectPath, claudeClient: claudeClient)
  }

  func configure(
    sessionId: String?,
    projectPath: String,
    claudeClient: (any ClaudeCode)?,
    initialPrompt: String? = nil
  ) {
    guard !isConfigured else { return }
    isConfigured = true

    // Create and configure terminal view
    let terminal = LocalProcessTerminalView(frame: bounds)
    terminal.translatesAutoresizingMaskIntoConstraints = false

    // Configure terminal appearance
    configureTerminalAppearance(terminal)

    // Add to view hierarchy
    addSubview(terminal)
    NSLayoutConstraint.activate([
      terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
      terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
      terminal.topAnchor.constraint(equalTo: topAnchor),
      terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])

    self.terminalView = terminal

    // Start the Claude process
    startClaudeProcess(
      terminal: terminal,
      sessionId: sessionId,
      projectPath: projectPath,
      claudeClient: claudeClient,
      initialPrompt: initialPrompt
    )
  }

  /// Sends a prompt to the terminal if not already sent
  func sendPromptIfNeeded(_ prompt: String) {
    guard !promptSent, let terminal = terminalView else { return }
    promptSent = true

    // Send the prompt text first
    terminal.send(txt: prompt)

    // Small delay before sending Enter to ensure the terminal's input buffer
    // processes the text before receiving the carriage return
    Task { @MainActor [weak terminal] in
      try? await Task.sleep(for: .milliseconds(100))
      terminal?.send([13])  // ASCII 13 = carriage return (Enter key)
    }
  }

  private func configureTerminalAppearance(_ terminal: LocalProcessTerminalView) {
    // Use a monospace font that looks good in terminals
    let fontSize: CGFloat = 12
    let font = NSFont(name: "SF Mono", size: fontSize)
      ?? NSFont(name: "Menlo", size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    terminal.font = font

    // Configure colors for dark theme (terminal typically uses dark background)
    terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
    terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)

    // Set cursor color to match brand (bookCloth color)
    terminal.caretColor = NSColor(red: 204/255, green: 120/255, blue: 92/255, alpha: 1.0)
  }

  private func startClaudeProcess(
    terminal: LocalProcessTerminalView,
    sessionId: String?,
    projectPath: String,
    claudeClient: (any ClaudeCode)?,
    initialPrompt: String? = nil
  ) {
    // Find the Claude executable
    let command = claudeClient?.configuration.command ?? "claude"
    let additionalPaths = claudeClient?.configuration.additionalPaths

    guard let executablePath = TerminalLauncher.findClaudeExecutable(
      command: command,
      additionalPaths: additionalPaths
    ) else {
      // Show error in terminal
      terminal.feed(text: "\r\n\u{001B}[31mError: Could not find '\(command)' command.\u{001B}[0m\r\n")
      terminal.feed(text: "Please ensure Claude Code CLI is installed.\r\n")
      return
    }

    // Build environment with PATH
    var environment = ProcessInfo.processInfo.environment

    // Enable full color support for Claude Code CLI
    // These tell the CLI that the terminal supports 256 colors and true color (24-bit RGB)
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"

    let paths = (additionalPaths ?? []) + [
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin",
      "\(NSHomeDirectory())/.claude/local"
    ]
    let pathString = paths.joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }

    // Build the shell command with working directory
    // Since SwiftTerm's Mac API doesn't support currentDirectory directly,
    // we use bash -c to cd first then run claude
    let workingDirectory = projectPath.isEmpty ? NSHomeDirectory() : projectPath
    let escapedPath = workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
    let escapedClaudePath = executablePath.replacingOccurrences(of: "'", with: "'\\''")
#if DEBUG
    let homeEnv = environment["HOME"] ?? "<nil>"
    AppLogger.session.debug(
      "[ClaudeProcess] workingDirectory=\(workingDirectory, privacy: .public) homeEnv=\(homeEnv, privacy: .public) command=\(command, privacy: .public)"
    )
#endif

    // Build command: resume existing session (-r) or start new session
    let shellCommand: String
    if let sessionId = sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
      // Resume existing session
      let escapedSessionId = sessionId.replacingOccurrences(of: "'", with: "'\\''")

      // Include initial prompt if provided (for inline edit requests)
      if let prompt = initialPrompt, !prompt.isEmpty {
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        shellCommand = "cd '\(escapedPath)' && '\(escapedClaudePath)' -r '\(escapedSessionId)' '\(escapedPrompt)'"
      } else {
        shellCommand = "cd '\(escapedPath)' && '\(escapedClaudePath)' -r '\(escapedSessionId)'"
      }
    } else {
      // Start NEW session (no -r flag)
      // Include initial prompt if provided (triggers immediate session file creation)
      if let prompt = initialPrompt, !prompt.isEmpty {
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        shellCommand = "cd '\(escapedPath)' && '\(escapedClaudePath)' '\(escapedPrompt)'"
      } else {
        shellCommand = "cd '\(escapedPath)' && '\(escapedClaudePath)'"
      }
    }

    // Start bash with the command
    terminal.startProcess(
      executable: "/bin/bash",
      args: ["-c", shellCommand],
      environment: environment.map { "\($0.key)=\($0.value)" }
    )

    // Find and store the new claude PID asynchronously
    // We capture PIDs before and after a delay to find the new one
    Task.detached { [weak self] in
      // Get PIDs right after starting (process may not be fully up yet)
      let initialPids = Self.getClaudePidsSync()

      // Wait for claude process to fully start
      try? await Task.sleep(for: .milliseconds(800))

      // Find the new claude process
      let currentPids = Self.getClaudePidsSync()
      let newPids = currentPids.subtracting(initialPids)

      if let newPid = newPids.first {
        await MainActor.run {
          self?.shellPid = newPid
        }
      }
    }
  }

  /// Gets currently running claude PIDs synchronously (safe to call from background thread)
  /// Has a 5-second timeout to prevent hanging if ps is unresponsive
  private nonisolated static func getClaudePidsSync() -> Set<pid_t> {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-eo", "pid,comm"]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()

    do {
      try task.run()

      // Use a semaphore with timeout to prevent hanging
      let semaphore = DispatchSemaphore(value: 0)
      var processFinished = false

      DispatchQueue.global(qos: .utility).async {
        task.waitUntilExit()
        processFinished = true
        semaphore.signal()
      }

      // Wait up to 5 seconds
      let result = semaphore.wait(timeout: .now() + 5.0)
      if result == .timedOut {
        task.terminate()
        AppLogger.session.warning("getClaudePidsSync timed out - ps command took too long")
        return []
      }

      guard processFinished else { return [] }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else { return [] }

      var pids = Set<pid_t>()
      for line in output.components(separatedBy: .newlines) {
        let parts = line.trimmingCharacters(in: .whitespaces)
          .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let pid = pid_t(parts[0]),
              parts[1] == "claude" else { continue }
        pids.insert(pid)
      }
      return pids
    } catch {
      AppLogger.session.error("getClaudePidsSync failed: \(error.localizedDescription)")
      return []
    }
  }
}

// MARK: - Preview

#Preview("Resume Session") {
  EmbeddedTerminalView(
    terminalKey: "test-session-123",
    sessionId: "test-session-123",
    projectPath: "/Users/test/project",
    claudeClient: nil
  )
  .frame(width: 600, height: 400)
}

#Preview("New Session") {
  EmbeddedTerminalView(
    terminalKey: "pending-preview",
    projectPath: "/Users/test/project",
    claudeClient: nil
  )
  .frame(width: 600, height: 400)
}
