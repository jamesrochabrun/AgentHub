//
//  ContextProfileRecord.swift
//  AgentHub
//
//  SQLite record for one saved context profile.
//

import Foundation
import GRDB

/// Persisted context profile.
///
/// The evolving part of a profile — its selection (file paths, future slices,
/// instructions) — is stored as an encoded `ContextSelection` blob so it can
/// grow without migrations; `payloadVersion` versions that payload. Everything
/// else (name, scope, default flag, timestamps) is queried or listed without
/// decoding, so those are real columns — and because the selection is the
/// *only* thing in the payload, a column update like flipping `isDefault`
/// cannot drift from a stale copy inside the blob.
public struct ContextProfileRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
  public static let currentPayloadVersion = 1

  public var id: String
  /// Storage scope: normalized repo root, or "" for personal (user-level) profiles.
  public var projectPath: String
  public var scope: String
  public var name: String
  public var isDefault: Bool
  public var createdAt: Date
  public var updatedAt: Date
  public var payloadVersion: Int
  public var payloadData: Data

  public static var databaseTableName: String { "context_profiles" }

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
    scope: String,
    name: String,
    isDefault: Bool,
    createdAt: Date,
    updatedAt: Date,
    payloadVersion: Int,
    payloadData: Data
  ) {
    self.id = id
    self.projectPath = projectPath
    self.scope = scope
    self.name = name
    self.isDefault = isDefault
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.payloadVersion = payloadVersion
    self.payloadData = payloadData
  }

  public init(profile: ContextProfile) throws {
    self.init(
      id: profile.id,
      projectPath: profile.scope == .personal ? "" : profile.projectPath,
      scope: profile.scope.rawValue,
      name: profile.name,
      isDefault: profile.isDefault,
      createdAt: profile.createdAt,
      updatedAt: profile.updatedAt,
      payloadVersion: Self.currentPayloadVersion,
      payloadData: try Self.payloadEncoder.encode(profile.selection)
    )
  }

  public func decodedProfile() throws -> ContextProfile {
    ContextProfile(
      id: id,
      name: name,
      scope: ContextProfileScope(rawValue: scope) ?? .project,
      projectPath: projectPath,
      selection: try Self.payloadDecoder.decode(ContextSelection.self, from: payloadData),
      isDefault: isDefault,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
