//
//  AIModelOption.swift
//  AgentHub
//
//  A single selectable model surfaced in the AI configuration picker.
//

import Foundation

/// A reasoning/effort level a model supports, as reported by the provider.
public struct AIReasoningEffort: Identifiable, Hashable, Sendable {
  /// The `--effort` value (e.g. "low", "medium", "high", "xhigh").
  public let effort: String
  /// Provider-supplied one-line explanation of the level, if any.
  public let description: String?

  public var id: String { effort }

  public init(effort: String, description: String? = nil) {
    self.effort = effort
    self.description = description
  }
}

/// A model the user can pick for a provider.
///
/// `identifier` is the exact value passed to the CLI `--model` flag — a Codex
/// slug like `gpt-5.5`, a Claude alias like `opus`, or a fully versioned id
/// like `claude-opus-4-8`. An empty identifier represents "use the CLI default"
/// (AgentHub omits `--model` entirely), so it is never stored as an option here;
/// the UI offers the default as a separate, empty selection.
public struct AIModelOption: Identifiable, Hashable, Sendable {
  /// Value passed to `--model`.
  public let identifier: String
  /// Human-facing name (e.g. "GPT-5.5", "Opus", or the raw id when none is known).
  public let displayName: String
  /// Optional one-line context shown beside the selection (model description,
  /// "Latest Opus (alias)", "Used in your sessions", …).
  public let detail: String?
  /// Reasoning levels this model supports (Codex reports these; empty when unknown).
  public let reasoningEfforts: [AIReasoningEffort]
  /// The model's default reasoning level, if the provider reports one.
  public let defaultReasoningEffort: String?

  public var id: String { identifier }

  public init(
    identifier: String,
    displayName: String,
    detail: String? = nil,
    reasoningEfforts: [AIReasoningEffort] = [],
    defaultReasoningEffort: String? = nil
  ) {
    self.identifier = identifier
    self.displayName = displayName
    self.detail = detail
    self.reasoningEfforts = reasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
  }
}
