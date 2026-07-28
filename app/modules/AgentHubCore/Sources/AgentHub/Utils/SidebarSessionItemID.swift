//
//  SidebarSessionItemID.swift
//  AgentHub
//

import Foundation

/// Identity of a sidebar session row.
///
/// A row is not identified by its bare session id: the sidebar unions Claude
/// and Codex sessions into one list, and pending (not-yet-real) sessions have
/// no session id at all. Everything that persists or scrolls to a row keys off
/// these strings, so they live in one place rather than being re-spelled at
/// each call site.
enum SidebarSessionItemID {
  /// Identity of a row backed by a real, monitored session.
  static func monitored(provider: SessionProviderKind, sessionId: String) -> String {
    "\(provider.rawValue.lowercased())-\(sessionId)"
  }

  /// Identity of a row for a session that is still launching.
  static func pending(provider: SessionProviderKind, pendingId: UUID) -> String {
    "pending-\(provider.rawValue.lowercased())-\(pendingId.uuidString)"
  }
}
