//
//  SessionMeasurementRecord.swift
//  AgentHub
//
//  SQLite record for one measurement an agent filed into a session's Measurements panel.
//

import AgentHubCLIKit
import Foundation
import GRDB

/// Persisted measurement card.
///
/// The measurement itself is stored as an encoded `MeasurementRecord` blob rather than
/// a column per field: the card's shape (chart kinds, caveats, future provenance)
/// evolves with the feature, and a blob keeps that evolution out of the migration
/// list. `payloadVersion` is the table-specific version for that encoded payload —
/// the one case the schema rules allow a per-table version column. Only the
/// columns the app actually queries on are denormalized.
public struct SessionMeasurementRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
  public static let currentPayloadVersion = 1

  public var id: String
  /// The project this measurement belongs to — the storage scope. Worktrees roll
  /// up to their parent repo (see `MeasurementProjectScope`).
  public var projectPath: String
  /// Which session filed it. Provenance only: measurements are *not* scoped to a
  /// session, so this is never used to decide what the panel shows.
  public var sessionId: String
  public var provider: String
  public var createdAt: Date
  public var payloadVersion: Int
  public var payloadData: Data

  public static var databaseTableName: String { "session_measurements" }

  /// Coders pinned to ISO-8601 so a payload written by one build always decodes
  /// in the next one.
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
    createdAt: Date,
    payloadVersion: Int,
    payloadData: Data
  ) {
    self.id = id
    self.projectPath = projectPath
    self.sessionId = sessionId
    self.provider = provider
    self.createdAt = createdAt
    self.payloadVersion = payloadVersion
    self.payloadData = payloadData
  }

  /// Wraps a measurement filed by the CLI. A measurement with no resolvable project is
  /// dropped upstream rather than stored where nothing would ever show it.
  public init(measurement: MeasurementRecord, projectPath: String, sessionId: String) throws {
    self.init(
      id: measurement.id,
      projectPath: projectPath,
      sessionId: sessionId,
      provider: measurement.sourceProvider.commandLineValue,
      createdAt: measurement.createdAt,
      payloadVersion: Self.currentPayloadVersion,
      payloadData: try Self.payloadEncoder.encode(measurement)
    )
  }

  public func decodedMeasurement() throws -> MeasurementRecord {
    try Self.payloadDecoder.decode(MeasurementRecord.self, from: payloadData)
  }
}
