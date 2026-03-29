//
//  CLIPathResolver.swift
//  AgentHub
//
//  Shared CLI path resolution so process services, embedded terminals,
//  and external terminal launches stay in parity.
//

import Foundation

enum CLIPathResolver {

  static func commonDeveloperPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
    [
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin",
      "\(homeDirectory)/.nvm/current/bin",
      "\(homeDirectory)/.nvm/versions/node/v22.16.0/bin",
      "\(homeDirectory)/.nvm/versions/node/v20.11.1/bin",
      "\(homeDirectory)/.nvm/versions/node/v18.19.0/bin",
      "\(homeDirectory)/.bun/bin",
      "\(homeDirectory)/.deno/bin",
      "\(homeDirectory)/.cargo/bin",
      "\(homeDirectory)/.local/bin"
    ]
  }

  static func claudePaths(
    additionalPaths: [String],
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    uniquePaths(
      ["\(homeDirectory)/.claude/local"] + additionalPaths + commonDeveloperPaths(homeDirectory: homeDirectory)
    )
  }

  static func codexPaths(
    additionalPaths: [String],
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    uniquePaths(
      additionalPaths
        + ["\(homeDirectory)/.codex/local", "\(homeDirectory)/.codex/bin"]
        + commonDeveloperPaths(homeDirectory: homeDirectory)
    )
  }

  static func executableSearchPaths(
    additionalPaths: [String] = [],
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    uniquePaths(
      additionalPaths
        + ["\(homeDirectory)/.claude/local", "\(homeDirectory)/.codex/local", "\(homeDirectory)/.codex/bin"]
        + commonDeveloperPaths(homeDirectory: homeDirectory)
    )
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }
}
