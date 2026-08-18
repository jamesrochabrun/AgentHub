//
//  ClaudeArtifact.swift
//  AgentHub
//
//  A Claude artifact (https://claude.ai/code/artifact/<id>) published by an
//  agent during a session and rendered in the Artifact side panel.
//

import Foundation

// MARK: - ClaudeArtifact

/// An artifact page the agent published from this session.
///
/// Parsed out of the session JSONL — either from the `Artifact` tool's
/// publish result (which carries a title and the source file path) or from a
/// bare artifact URL mentioned in the transcript.
public struct ClaudeArtifact: Identifiable, Equatable, Hashable, Sendable {
  /// The artifact id from the URL path; also the identity used for dedupe, so a
  /// republish updates the existing entry instead of appending a duplicate.
  public let id: String
  /// Canonical page URL (query/fragment stripped — `?via=…` is provenance).
  public let url: URL
  public var title: String?
  /// Local file the artifact was published from, when the publish result named one.
  public var filePath: String?
  /// Bumped on every republish. The open panel watches this to reload the same
  /// URL when the content behind it changes.
  public var revision: Int
  public var detectedAt: Date

  public init(
    id: String,
    url: URL,
    title: String? = nil,
    filePath: String? = nil,
    revision: Int = 0,
    detectedAt: Date = Date()
  ) {
    self.id = id
    self.url = url
    self.title = title
    self.filePath = filePath
    self.revision = revision
    self.detectedAt = detectedAt
  }

  /// Title for the picker/header, falling back to the source file name and then
  /// to a short id so an untitled artifact is still distinguishable.
  public var displayTitle: String {
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return title
    }
    if let fileName = filePath?.split(separator: "/").last, !fileName.isEmpty {
      return String(fileName)
    }
    return "Artifact \(id.prefix(8))"
  }
}
