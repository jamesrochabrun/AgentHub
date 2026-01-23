//
//  TerminalLauncher.swift
//  AgentHub
//
//  Created by Assistant on 12/24/24.
//

import Foundation
import AppKit
import ClaudeCodeSDK

/// Helper object to handle launching Terminal with Claude sessions
public struct TerminalLauncher {

  /// Runs a Claude session in the background without opening Terminal
  /// - Parameters:
  ///   - sessionId: The session ID to resume
  ///   - claudeClient: The Claude client with configuration
  ///   - projectPath: The project path to use as working directory
  ///   - prompt: The prompt to send to Claude
  ///   - onOutput: Called with each chunk of output text
  ///   - onComplete: Called when the process finishes (with error if failed)
  @MainActor
  public static func runSessionInBackground(
    _ sessionId: String,
    claudeClient: ClaudeCode,
    projectPath: String,
    prompt: String,
    onOutput: @escaping @MainActor (String) -> Void,
    onComplete: @escaping @MainActor (Error?) -> Void
  ) {
    let claudeCommand = claudeClient.configuration.command

    guard let claudeExecutablePath = findClaudeExecutable(
      command: claudeCommand,
      additionalPaths: claudeClient.configuration.additionalPaths
    ) else {
      let error = NSError(
        domain: "TerminalLauncher",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not find '\(claudeCommand)' command. Please ensure Claude Code CLI is installed."]
      )
      onComplete(error)
      return
    }

    Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: claudeExecutablePath)
      process.arguments = ["-r", sessionId, prompt]

      if !projectPath.isEmpty {
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
      }

      // Set up environment with PATH for child processes
      var environment = ProcessInfo.processInfo.environment
      let additionalPaths = claudeClient.configuration.additionalPaths.joined(separator: ":")
      if let existingPath = environment["PATH"] {
        environment["PATH"] = "\(additionalPaths):\(existingPath)"
      } else {
        environment["PATH"] = additionalPaths
      }
      process.environment = environment

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      // Handle stdout streaming
      stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
          Task { @MainActor in
            onOutput(text)
          }
        }
      }

      // Handle stderr (also stream to output for visibility)
      stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
          Task { @MainActor in
            onOutput(text)
          }
        }
      }

      process.terminationHandler = { process in
        // Clean up handlers
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        Task { @MainActor in
          if process.terminationStatus != 0 {
            let error = NSError(
              domain: "TerminalLauncher",
              code: Int(process.terminationStatus),
              userInfo: [NSLocalizedDescriptionKey: "Process exited with status \(process.terminationStatus)"]
            )
            onComplete(error)
          } else {
            onComplete(nil)
          }
        }
      }

      do {
        try process.run()
      } catch {
        Task { @MainActor in
          onComplete(error)
        }
      }
    }
  }

  /// Launches Terminal with a Claude session resume command
  /// - Parameters:
  ///   - sessionId: The session ID to resume
  ///   - claudeClient: The Claude client with configuration
  ///   - projectPath: The project path to change to before resuming
  ///   - initialPrompt: Optional initial prompt to send to Claude
  /// - Returns: An error if launching fails, nil on success
  public static func launchTerminalWithSession(
    _ sessionId: String,
    claudeClient: ClaudeCode,
    projectPath: String,
    initialPrompt: String? = nil
  ) -> Error? {
    // Get the claude command from configuration
    let claudeCommand = claudeClient.configuration.command

    // Find the full path to the claude executable
    guard let claudeExecutablePath = findClaudeExecutable(
      command: claudeCommand,
      additionalPaths: claudeClient.configuration.additionalPaths
    ) else {
      return NSError(
        domain: "TerminalLauncher",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not find '\(claudeCommand)' command. Please ensure Claude Code CLI is installed."]
      )
    }

    // Escape paths for shell
    let escapedPath = projectPath.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let escapedClaudePath = claudeExecutablePath.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let escapedSessionId = sessionId.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    // Escape the initial prompt if provided
    let escapedPrompt = initialPrompt?
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "'", with: "'\\''")

    // Construct the command
    let command: String
    if !projectPath.isEmpty {
      if let prompt = escapedPrompt {
        command = "cd \"\(escapedPath)\" && \"\(escapedClaudePath)\" -r \"\(escapedSessionId)\" '\(prompt)'"
      } else {
        command = "cd \"\(escapedPath)\" && \"\(escapedClaudePath)\" -r \"\(escapedSessionId)\""
      }
    } else {
      if let prompt = escapedPrompt {
        command = "\"\(escapedClaudePath)\" -r \"\(escapedSessionId)\" '\(prompt)'"
      } else {
        command = "\"\(escapedClaudePath)\" -r \"\(escapedSessionId)\""
      }
    }

    // Create a temporary script file
    let tempDir = NSTemporaryDirectory()
    let scriptPath = (tempDir as NSString).appendingPathComponent("claude_resume_\(UUID().uuidString).command")

    // Create the script content
    let scriptContent = """
    #!/bin/bash
    \(command)
    """

    do {
      // Write the script to file
      try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)

      // Make it executable
      let attributes = [FileAttributeKey.posixPermissions: 0o755]
      try FileManager.default.setAttributes(attributes, ofItemAtPath: scriptPath)

      // Open the script with Terminal
      let url = URL(fileURLWithPath: scriptPath)
      NSWorkspace.shared.open(url)

      // Clean up the script file after a delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        try? FileManager.default.removeItem(atPath: scriptPath)
      }

      return nil
    } catch {
      return NSError(
        domain: "TerminalLauncher",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to launch Terminal: \(error.localizedDescription)"]
      )
    }
  }

  /// Launches Terminal with a new Claude session in the specified path
  /// - Parameters:
  ///   - path: The directory path to open
  ///   - branchName: The branch to checkout (for non-worktrees)
  ///   - isWorktree: Whether this is a worktree (skips branch checkout)
  ///   - skipCheckout: If true, skips checkout even for non-worktrees (already on correct branch)
  ///   - claudeClient: The Claude client with configuration
  ///   - initialPrompt: Optional initial prompt to send to Claude
  /// - Returns: An error if launching fails, nil on success
  public static func launchTerminalInPath(
    _ path: String,
    branchName: String,
    isWorktree: Bool,
    skipCheckout: Bool = false,
    claudeClient: ClaudeCode,
    initialPrompt: String? = nil
  ) -> Error? {
    let claudeCommand = claudeClient.configuration.command

    guard let claudeExecutablePath = findClaudeExecutable(
      command: claudeCommand,
      additionalPaths: claudeClient.configuration.additionalPaths
    ) else {
      return NSError(
        domain: "TerminalLauncher",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not find '\(claudeCommand)' command. Please ensure Claude Code CLI is installed."]
      )
    }

    let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let escapedClaudePath = claudeExecutablePath.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let escapedBranch = branchName.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    // Escape the initial prompt if provided
    let escapedPrompt = initialPrompt?
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "'", with: "'\\''")

    // Build the command - for worktrees or when skipCheckout is true, just cd and run claude
    // Otherwise, checkout the branch first
    let command: String
    if isWorktree || skipCheckout {
      if let prompt = escapedPrompt {
        command = "cd \"\(escapedPath)\" && \"\(escapedClaudePath)\" '\(prompt)'"
      } else {
        command = "cd \"\(escapedPath)\" && \"\(escapedClaudePath)\""
      }
    } else {
      command = "cd \"\(escapedPath)\" && git checkout \"\(escapedBranch)\" && \"\(escapedClaudePath)\""
    }

    let tempDir = NSTemporaryDirectory()
    let scriptPath = (tempDir as NSString).appendingPathComponent("claude_open_\(UUID().uuidString).command")

    let scriptContent = """
    #!/bin/bash
    \(command)
    """

    do {
      try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
      let attributes = [FileAttributeKey.posixPermissions: 0o755]
      try FileManager.default.setAttributes(attributes, ofItemAtPath: scriptPath)

      let url = URL(fileURLWithPath: scriptPath)
      NSWorkspace.shared.open(url)

      // Clean up script after Terminal has had time to read it
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        try? FileManager.default.removeItem(atPath: scriptPath)
      }

      return nil
    } catch {
      return NSError(
        domain: "TerminalLauncher",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to launch Terminal: \(error.localizedDescription)"]
      )
    }
  }

  /// Finds the full path to the Claude executable
  /// - Parameters:
  ///   - command: The command name to search for (e.g., "claude")
  ///   - additionalPaths: Additional paths to search from configuration
  /// - Returns: The full path to the executable if found, nil otherwise
  public static func findClaudeExecutable(
    command: String,
    additionalPaths: [String]?
  ) -> String? {
    let fileManager = FileManager.default
    let homeDir = NSHomeDirectory()

    // Default search paths
    let defaultPaths = [
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin",
      "\(homeDir)/.claude/local",
      "\(homeDir)/.nvm/current/bin",
      "\(homeDir)/.nvm/versions/node/v22.16.0/bin",
      "\(homeDir)/.nvm/versions/node/v20.11.1/bin",
      "\(homeDir)/.nvm/versions/node/v18.19.0/bin"
    ]

    // Combine additional paths with default paths
    let allPaths = (additionalPaths ?? []) + defaultPaths

    // Search for the command in all paths
    for path in allPaths {
      let fullPath = "\(path)/\(command)"
      if fileManager.fileExists(atPath: fullPath) {
        return fullPath
      }
    }

    // Fallback: try using 'which' command
    let task = Process()
    task.launchPath = "/usr/bin/which"
    task.arguments = [command]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()

    do {
      try task.run()
      task.waitUntilExit()

      if task.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
          return path
        }
      }
    } catch {
      // Ignore errors from which command
    }

    return nil
  }
}
