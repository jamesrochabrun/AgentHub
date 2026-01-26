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

// MARK: - SafeLocalProcessTerminalView

/// A ManagedLocalProcessTerminalView subclass that safely handles cleanup by stopping
/// data reception before process termination. This prevents crashes when the
/// terminal buffer receives data during deallocation.
class SafeLocalProcessTerminalView: ManagedLocalProcessTerminalView {
  private var _isStopped = false
  private let stopLock = NSLock()

  var isStopped: Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return _isStopped
  }

  /// Call this BEFORE terminating the process to safely stop data reception.
  func stopReceivingData() {
    stopLock.lock()
    _isStopped = true
    stopLock.unlock()
  }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    guard !isStopped else { return }
    super.dataReceived(slice: slice)
  }
}

// MARK: - EmbeddedTerminalView

/// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView
/// Provides an embedded terminal for interacting with Claude sessions
public struct EmbeddedTerminalView: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme

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
    let isDark = colorScheme == .dark

    // Use shared terminal storage if viewModel is provided
    if let viewModel = viewModel {
      return viewModel.getOrCreateTerminal(
        forKey: terminalKey,
        sessionId: sessionId,
        projectPath: projectPath,
        claudeClient: claudeClient,
        initialPrompt: initialPrompt,
        isDark: isDark
      )
    }

    // Fallback: create standalone terminal (for previews)
    let containerView = TerminalContainerView()
    containerView.configure(
      sessionId: sessionId,
      projectPath: projectPath,
      claudeClient: claudeClient,
      initialPrompt: initialPrompt,
      isDark: isDark
    )
    return containerView
  }

  public func updateNSView(_ nsView: TerminalContainerView, context: Context) {
    // Update colors when color scheme changes
    nsView.updateColors(isDark: colorScheme == .dark)

    // If there's a pending prompt, send it to the existing terminal and clear it
    if let prompt = initialPrompt, let sessionId = sessionId {
      nsView.sendPromptIfNeeded(prompt)
      viewModel?.clearPendingPrompt(for: sessionId)
    }
  }
}

// MARK: - TerminalContainerView

/// Container view that manages the terminal lifecycle
public class TerminalContainerView: NSView, ManagedLocalProcessTerminalViewDelegate {
  private var terminalView: SafeLocalProcessTerminalView?
  private var isConfigured = false
  private var terminalPidMap: [ObjectIdentifier: pid_t] = [:]

  // MARK: - Lifecycle

  /// Terminate process on deallocation (safety net)
  deinit {
    terminateProcess()
  }

  /// Explicitly terminates the terminal process and its children.
  /// Call this before removing the terminal from activeTerminals to ensure cleanup.
  /// Safe to call multiple times - subsequent calls are no-ops.
  public func terminateProcess() {
    // Stop data reception FIRST to prevent DispatchIO race condition crash
    terminalView?.stopReceivingData()
    terminalView?.terminateProcessTree()
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
    configure(sessionId: sessionId, projectPath: projectPath, claudeClient: claudeClient)
  }

  func configure(
    sessionId: String?,
    projectPath: String,
    claudeClient: (any ClaudeCode)?,
    initialPrompt: String? = nil,
    isDark: Bool = true
  ) {
    guard !isConfigured else { return }
    isConfigured = true

    // Create and configure terminal view
    let terminal = SafeLocalProcessTerminalView(frame: bounds)
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminal.processDelegate = self

    // Configure terminal appearance
    configureTerminalAppearance(terminal, isDark: isDark)

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
    registerProcessIfNeeded(for: terminal)
  }

  /// Sends a prompt to the terminal
  func sendPromptIfNeeded(_ prompt: String) {
    guard let terminal = terminalView else { return }

    // Send the prompt text first
    terminal.send(txt: prompt)

    // Small delay before sending Enter to ensure the terminal's input buffer
    // processes the text before receiving the carriage return
    Task { @MainActor [weak terminal] in
      try? await Task.sleep(for: .milliseconds(100))
      terminal?.send([13])  // ASCII 13 = carriage return (Enter key)
    }
  }

  /// Types text into the terminal WITHOUT pressing Enter.
  /// Used for drag-and-drop file paths where user adds context before submitting.
  public func typeText(_ text: String) {
    guard let terminal = terminalView else { return }
    terminal.send(txt: text)
  }

  /// Updates terminal colors based on color scheme.
  /// Called when the app's color scheme changes.
  public func updateColors(isDark: Bool) {
    guard let terminal = terminalView else { return }

    if isDark {
      terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)
    } else {
      terminal.nativeBackgroundColor = NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    }

    // Force redraw
    terminal.needsDisplay = true
  }

  private func configureTerminalAppearance(_ terminal: TerminalView, isDark: Bool) {
    // Use a monospace font that looks good in terminals
    let fontSize: CGFloat = 12
    let font = NSFont(name: "SF Mono", size: fontSize)
      ?? NSFont(name: "Menlo", size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    terminal.font = font

    // Configure colors based on color scheme
    if isDark {
      terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)
    } else {
      terminal.nativeBackgroundColor = NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    }

    // Set cursor color to match brand (bookCloth color)
    terminal.caretColor = NSColor(red: 204/255, green: 120/255, blue: 92/255, alpha: 1.0)
  }

  private func startClaudeProcess(
    terminal: ManagedLocalProcessTerminalView,
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
        shellCommand = "cd '\(escapedPath)' && exec '\(escapedClaudePath)' -r '\(escapedSessionId)' '\(escapedPrompt)'"
      } else {
        shellCommand = "cd '\(escapedPath)' && exec '\(escapedClaudePath)' -r '\(escapedSessionId)'"
      }
    } else {
      // Start NEW session (no -r flag)
      // Include initial prompt if provided (triggers immediate session file creation)
      if let prompt = initialPrompt, !prompt.isEmpty {
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        shellCommand = "cd '\(escapedPath)' && exec '\(escapedClaudePath)' '\(escapedPrompt)'"
      } else {
        shellCommand = "cd '\(escapedPath)' && exec '\(escapedClaudePath)'"
      }
    }

    // Start bash with the command
    terminal.startProcess(
      executable: "/bin/bash",
      args: ["-c", shellCommand],
      environment: environment.map { "\($0.key)=\($0.value)" }
    )
  }

  private func registerProcessIfNeeded(for terminal: SafeLocalProcessTerminalView) {
    guard let pid = terminal.currentProcessId, pid > 0 else { return }
    let key = ObjectIdentifier(terminal)
    terminalPidMap[key] = pid
    TerminalProcessRegistry.shared.register(pid: pid)
  }

  // MARK: - ManagedLocalProcessTerminalViewDelegate

  public func sizeChanged(source: ManagedLocalProcessTerminalView, newCols: Int, newRows: Int) {}

  public func setTerminalTitle(source: ManagedLocalProcessTerminalView, title: String) {}

  public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  public func processTerminated(source: TerminalView, exitCode: Int32?) {
    let key = ObjectIdentifier(source)
    if let pid = terminalPidMap[key] {
      TerminalProcessRegistry.shared.unregister(pid: pid)
      terminalPidMap.removeValue(forKey: key)
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
