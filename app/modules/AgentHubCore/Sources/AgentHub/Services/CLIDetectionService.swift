//
//  CLIDetectionService.swift
//  AgentHub
//
//  Detects installed CLI tools by checking executables and data directories.
//

import Foundation

/// Service for detecting installed CLI tools
public struct CLIDetectionService {

  /// Result of CLI detection
  public struct DetectionResult {
    public let claudeInstalled: Bool
    public let codexInstalled: Bool

    /// At least one CLI is installed
    public var hasAnyCLI: Bool {
      claudeInstalled || codexInstalled
    }
  }

  /// Checks if Claude CLI is installed
  /// Detection checks: executable path OR ~/.claude data directory exists
  /// - Parameter additionalPaths: Additional paths to search for executable
  /// - Returns: true if Claude CLI is detected
  public static func isClaudeInstalled(additionalPaths: [String]? = nil) -> Bool {
    // Check executable
    if TerminalLauncher.findClaudeExecutable(command: "claude", additionalPaths: additionalPaths) != nil {
      return true
    }
    // Check data directory
    let claudeDataPath = NSHomeDirectory() + "/.claude"
    return FileManager.default.fileExists(atPath: claudeDataPath)
  }

  /// Checks if Codex CLI is installed
  /// Detection checks: executable path OR ~/.codex data directory exists
  /// - Parameter additionalPaths: Additional paths to search for executable
  /// - Returns: true if Codex CLI is detected
  public static func isCodexInstalled(additionalPaths: [String]? = nil) -> Bool {
    // Check executable
    if TerminalLauncher.findCodexExecutable(additionalPaths: additionalPaths) != nil {
      return true
    }
    // Check data directory
    let codexDataPath = NSHomeDirectory() + "/.codex"
    return FileManager.default.fileExists(atPath: codexDataPath)
  }

  /// Detects which CLI tools are installed
  /// - Parameter additionalPaths: Additional paths to search
  /// - Returns: Detection result indicating which CLIs are found
  public static func detectInstalledCLIs(additionalPaths: [String]? = nil) -> DetectionResult {
    return DetectionResult(
      claudeInstalled: isClaudeInstalled(additionalPaths: additionalPaths),
      codexInstalled: isCodexInstalled(additionalPaths: additionalPaths)
    )
  }
}
