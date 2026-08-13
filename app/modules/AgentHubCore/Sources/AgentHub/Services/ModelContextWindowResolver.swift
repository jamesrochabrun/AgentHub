//
//  ModelContextWindowResolver.swift
//  AgentHub
//
//  Resolves a model identifier to its context window, from local evidence
//  rather than a hardcoded constant:
//
//  - Codex models report `context_window` in `~/.codex/models_cache.json`
//    (already read by `CodexModelCatalog`) — real per-model data.
//  - Claude Code sessions record the resolved model per turn; ids carry a
//    `[1m]` suffix when the 1M-context beta is active. A plain Claude id runs
//    the standard 200K window regardless of what the raw API model supports,
//    so the suffix — not the model family — is the correct signal.
//  - Anything unknown falls back to a conservative 200K so budget warnings
//    err toward caution.
//

import Foundation

public enum ModelContextWindowResolver {

  /// Conservative fallback, and the Claude Code standard window.
  public static let conservativeDefaultTokens = 200_000

  /// Window for Claude ids carrying the 1M-context beta suffix.
  static let oneMillionTokens = 1_000_000

  /// Codex per-model windows from the on-disk models cache, read once.
  private static let cachedCodexWindows: [String: Int] = {
    var windows: [String: Int] = [:]
    for option in CodexModelCatalog().cachedModels() {
      if let tokens = option.contextWindowTokens {
        windows[option.identifier.lowercased()] = tokens
      }
    }
    return windows
  }()

  public static func window(forModelIdentifier identifier: String?) -> Int {
    window(forModelIdentifier: identifier, codexWindows: cachedCodexWindows)
  }

  /// Pure variant with an injectable Codex lookup, for tests.
  static func window(forModelIdentifier identifier: String?, codexWindows: [String: Int]) -> Int {
    guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !identifier.isEmpty
    else {
      return conservativeDefaultTokens
    }

    if identifier.hasSuffix("[1m]") {
      return oneMillionTokens
    }
    if let codexWindow = codexWindows[identifier] {
      return codexWindow
    }
    return conservativeDefaultTokens
  }
}
