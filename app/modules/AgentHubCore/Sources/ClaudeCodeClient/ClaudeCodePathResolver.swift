//
//  ClaudeCodePathResolver.swift
//  ClaudeCodeClient
//

import Foundation

public enum ClaudeCodePathResolver {

  public static func commonDeveloperPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
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

  public static func searchPaths(
    additionalPaths: [String],
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    uniquePaths(
      ["\(homeDirectory)/.claude/local"] + additionalPaths + commonDeveloperPaths(homeDirectory: homeDirectory)
    )
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }
}
