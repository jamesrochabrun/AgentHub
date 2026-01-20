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
  let sessionId: String
  let projectPath: String
  let claudeClient: (any ClaudeCode)?

  public init(
    sessionId: String,
    projectPath: String,
    claudeClient: (any ClaudeCode)?
  ) {
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.claudeClient = claudeClient
  }

  public func makeNSView(context: Context) -> TerminalContainerView {
    let containerView = TerminalContainerView()
    containerView.configure(
      sessionId: sessionId,
      projectPath: projectPath,
      claudeClient: claudeClient
    )
    return containerView
  }

  public func updateNSView(_ nsView: TerminalContainerView, context: Context) {
    // Configuration is static after initial setup
  }
}

// MARK: - TerminalContainerView

/// Container view that manages the terminal lifecycle
public class TerminalContainerView: NSView {
  private var terminalView: LocalProcessTerminalView?
  private var isConfigured = false

  func configure(
    sessionId: String,
    projectPath: String,
    claudeClient: (any ClaudeCode)?
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
      claudeClient: claudeClient
    )
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
    sessionId: String,
    projectPath: String,
    claudeClient: (any ClaudeCode)?
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
    let escapedSessionId = sessionId.replacingOccurrences(of: "'", with: "'\\''")

    let shellCommand = "cd '\(escapedPath)' && '\(escapedClaudePath)' -r '\(escapedSessionId)'"

    // Start bash with the command
    terminal.startProcess(
      executable: "/bin/bash",
      args: ["-c", shellCommand],
      environment: environment.map { "\($0.key)=\($0.value)" }
    )
  }
}

// MARK: - Preview

#Preview {
  EmbeddedTerminalView(
    sessionId: "test-session-123",
    projectPath: "/Users/test/project",
    claudeClient: nil
  )
  .frame(width: 600, height: 400)
}
