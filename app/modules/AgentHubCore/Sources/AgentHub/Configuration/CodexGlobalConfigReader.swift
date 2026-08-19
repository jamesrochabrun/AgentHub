//
//  CodexGlobalConfigReader.swift
//  AgentHub
//
//  Reads the few top-level keys of the user's `~/.codex/config.toml` that
//  change how AgentHub must launch Codex. Read-only; AgentHub never writes it.
//

import Foundation

public enum CodexGlobalConfigReader {
  /// `~/.codex/config.toml`, honouring `CODEX_HOME` the way Codex does.
  public static func defaultConfigURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
        .appendingPathComponent("config.toml", isDirectory: false)
    }
    return homeDirectory
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)
  }

  /// The user's global `approval_policy` (`untrusted`, `on-request`,
  /// `on-failure`, `never`), or nil when unset/unreadable.
  ///
  /// Codex 0.148+ prompts per MCP tool call unless a server is `auto`, and a
  /// global `never` turns that prompt into a hard failure — a policy AgentHub
  /// cannot see from its own settings. Only the top-level key counts: a value
  /// inside a `[profiles.x]` or `[projects."…"]` table is scoped and ignored.
  public static func approvalPolicy(configURL: URL = defaultConfigURL()) -> String? {
    guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
    return topLevelValue(forKey: "approval_policy", in: content)
  }

  static func topLevelValue(forKey key: String, in content: String) -> String? {
    for rawLine in content.components(separatedBy: .newlines) {
      let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if line.hasPrefix("[") { return nil } // first table header ends the top level
      guard let equals = line.firstIndex(of: "=") else { continue }
      let name = line[..<equals].trimmingCharacters(in: .whitespaces)
      guard name == key else { continue }
      let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      return unquoted(raw)
    }
    return nil
  }

  private static func unquoted(_ value: String) -> String? {
    guard value.count >= 2 else { return value.isEmpty ? nil : value }
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
      return String(value.dropFirst().dropLast())
    }
    return value
  }

  private static func stripComment(_ line: String) -> String {
    var result = ""
    var quote: Character?
    var previous: Character?
    for character in line {
      if character == "\"" || character == "'" {
        if quote == nil { quote = character } else if quote == character, previous != "\\" { quote = nil }
      }
      if character == "#", quote == nil { break }
      result.append(character)
      previous = character
    }
    return result
  }
}
