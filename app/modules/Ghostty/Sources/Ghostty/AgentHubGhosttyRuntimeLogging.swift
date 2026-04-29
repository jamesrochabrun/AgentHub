//
//  AgentHubGhosttyRuntimeLogging.swift
//  AgentHub
//

import Darwin
import Foundation

enum AgentHubGhosttyRuntimeLogging {
  static let environmentKey = "GHOSTTY_LOG"
  private static let quietDefaultValue = "false"

  static func applyQuietDefault(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    setEnvironment: (String, String, Int32) -> Int32 = { key, value, overwrite in
      setenv(key, value, overwrite)
    }
  ) {
    guard environment[environmentKey] == nil else { return }
    _ = setEnvironment(environmentKey, quietDefaultValue, 0)
  }
}
