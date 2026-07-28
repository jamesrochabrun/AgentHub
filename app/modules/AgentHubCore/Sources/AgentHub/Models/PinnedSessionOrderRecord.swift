//
//  PinnedSessionOrderRecord.swift
//  AgentHub
//
//  Manual drag order for the sidebar's pinned section, stored in SQLite
//

import Foundation
import GRDB

/// One pinned sidebar row's manual position.
///
/// Keyed by the provider-scoped sidebar item id (`"claude-<sessionId>"`), not
/// the bare session id: the pinned section is a single list unioned across
/// Claude and Codex, so its order has to be expressible across both.
public struct PinnedSessionOrderRecord: Codable, Sendable, FetchableRecord, PersistableRecord {

  /// The sidebar item id this position belongs to
  public var itemId: String

  /// Zero-based position within the pinned section
  public var sortIndex: Int

  /// When the position was last written
  public var updatedAt: Date

  // MARK: - GRDB Configuration

  public static var databaseTableName: String { "pinned_session_order" }

  // MARK: - Initialization

  public init(
    itemId: String,
    sortIndex: Int,
    updatedAt: Date = Date()
  ) {
    self.itemId = itemId
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
  }
}
