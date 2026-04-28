//
//  GhosttyConfigPathResolver.swift
//  AgentHub
//

import Foundation

enum GhosttyConfigPathResolver {
  static func configuredPath(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) -> String? {
    guard let rawPath = defaults.string(forKey: AgentHubDefaults.terminalGhosttyConfigPath) else {
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
