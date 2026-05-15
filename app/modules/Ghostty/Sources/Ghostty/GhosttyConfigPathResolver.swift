//
//  GhosttyConfigPathResolver.swift
//  AgentHub
//

import AgentHubCore
import Foundation

public enum GhosttyConfigPathResolver {
  public static func configuredPath(
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
          !isDirectory.boolValue,
          fileManager.isReadableFile(atPath: expandedPath),
          isRegularFile(atPath: expandedPath) else {
      return nil
    }

    return expandedPath
  }

  private static func isRegularFile(atPath path: String) -> Bool {
    do {
      let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
      return values.isRegularFile == true
    } catch {
      return false
    }
  }
}
