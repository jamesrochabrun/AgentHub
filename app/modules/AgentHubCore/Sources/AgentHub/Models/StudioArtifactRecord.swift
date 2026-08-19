//
//  StudioArtifactRecord.swift
//  AgentHub
//
//  SQLite record for one artifact an agent filed into the Studio panel.
//

import AgentHubCLIKit
import Foundation
import GRDB

/// Persisted Studio artifact.
///
/// The artifact is stored as an encoded `StudioArtifact` blob rather than a
/// column per field: its shape (variants, warnings, future layout hints) evolves
/// with the feature, and a blob keeps that evolution out of the migration list.
/// `payloadVersion` is the table-specific version for that encoded payload — the
/// one case the schema rules allow a per-table version column. Only the columns
/// the app queries on are denormalized.
///
/// The database is the source of truth; the served `index.html` on disk is a
/// cache derived from this row and can always be rewritten from it.
public struct StudioArtifactRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
  public static let currentPayloadVersion = 1

  public var id: String
  /// The project this artifact belongs to — the storage scope. Worktrees roll
  /// up to their parent repo (see `MeasurementProjectScope`).
  public var projectPath: String
  /// Which session filed it. Provenance only; never used to decide what shows.
  public var sessionId: String
  public var provider: String
  public var kind: String
  public var createdAt: Date
  public var updatedAt: Date
  public var payloadVersion: Int
  public var payloadData: Data

  public static var databaseTableName: String { "studio_artifacts" }

  private static var payloadEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var payloadDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  public init(
    id: String,
    projectPath: String,
    sessionId: String,
    provider: String,
    kind: String,
    createdAt: Date,
    updatedAt: Date,
    payloadVersion: Int,
    payloadData: Data
  ) {
    self.id = id
    self.projectPath = projectPath
    self.sessionId = sessionId
    self.provider = provider
    self.kind = kind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.payloadVersion = payloadVersion
    self.payloadData = payloadData
  }

  /// `projectPath` is normalized here so a trailing slash can never split one
  /// project's artifacts across two keys.
  public init(artifact: StudioArtifact, projectPath: String, sessionId: String) throws {
    self.init(
      id: artifact.id,
      projectPath: MeasurementProjectScope.normalized(projectPath),
      sessionId: sessionId,
      provider: artifact.sourceProvider.commandLineValue,
      kind: artifact.kind.rawValue,
      createdAt: artifact.createdAt,
      updatedAt: artifact.displayDate,
      payloadVersion: Self.currentPayloadVersion,
      payloadData: try Self.payloadEncoder.encode(artifact)
    )
  }

  public func decodedArtifact() throws -> StudioArtifact {
    try Self.payloadDecoder.decode(StudioArtifact.self, from: payloadData)
  }
}
