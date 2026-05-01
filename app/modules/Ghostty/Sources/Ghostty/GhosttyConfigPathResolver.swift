//
//  GhosttyConfigPathResolver.swift
//  AgentHub
//

import AgentHubTerminalUI
import Foundation

public enum GhosttyConfigPathResolver {
  public static func configuredPath(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) -> String? {
    guard let rawPath = defaults.string(forKey: TerminalUserDefaultsKeys.terminalGhosttyConfigPath) else {
      return nil
    }

    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }

    let expandedPath = (path as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
          !isDirectory.boolValue else {
      return nil
    }

    return expandedPath
  }
}
