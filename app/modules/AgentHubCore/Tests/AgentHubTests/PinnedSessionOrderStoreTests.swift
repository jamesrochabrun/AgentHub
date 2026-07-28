import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Pinned session order store")
struct PinnedSessionOrderStoreTests {
  @Test("Order round-trips as dense positions")
  func orderRoundTrips() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())

    try await store.setPinnedSessionOrder(["claude-a", "codex-b", "claude-c"])

    #expect(try await store.getPinnedSessionOrder() == [
      "claude-a": 0,
      "codex-b": 1,
      "claude-c": 2
    ])
  }

  @Test("Rewriting the order replaces earlier positions instead of stacking them")
  func rewritingOrderReplacesPositions() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())

    try await store.setPinnedSessionOrder(["claude-a", "claude-b", "claude-c"])
    try await store.setPinnedSessionOrder(["claude-c", "claude-a", "claude-b"])

    let order = try await store.getPinnedSessionOrder()
    #expect(order == ["claude-c": 0, "claude-a": 1, "claude-b": 2])
    // No duplicate slots — every pinned row must have a position of its own.
    #expect(Set(order.values).count == order.count)
  }

  @Test("Synchronous read matches the async read")
  func syncReadMatchesAsyncRead() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())

    try await store.setPinnedSessionOrder(["claude-a", "codex-b"])

    #expect(store.getPinnedSessionOrderSync() == ["claude-a": 0, "codex-b": 1])
  }

  @Test("Empty order reads back empty rather than failing")
  func emptyOrderReadsBackEmpty() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())

    #expect(try await store.getPinnedSessionOrder().isEmpty)
    #expect(store.getPinnedSessionOrderSync().isEmpty)

    try await store.setPinnedSessionOrder([])
    #expect(try await store.getPinnedSessionOrder().isEmpty)
  }

  @Test("Order survives reopening the database")
  func orderSurvivesReopen() async throws {
    let path = temporaryPinnedOrderDatabasePath()
    let store = try SessionMetadataStore(path: path)
    try await store.setPinnedSessionOrder(["claude-a", "claude-b"])

    let reopened = try SessionMetadataStore(path: path)
    #expect(try await reopened.getPinnedSessionOrder() == ["claude-a": 0, "claude-b": 1])
  }

  @Test("Positions are provider-scoped, so identical session ids do not collide")
  func positionsAreProviderScoped() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())
    let sharedSessionId = "same-id"

    try await store.setPinnedSessionOrder([
      SidebarSessionItemID.monitored(provider: .codex, sessionId: sharedSessionId),
      SidebarSessionItemID.monitored(provider: .claude, sessionId: sharedSessionId)
    ])

    let order = try await store.getPinnedSessionOrder()
    #expect(order["codex-\(sharedSessionId)"] == 0)
    #expect(order["claude-\(sharedSessionId)"] == 1)
  }

  @Test("Explicitly deleting positions clears only the named rows")
  func deletingPositionsClearsOnlyNamedRows() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())
    try await store.setPinnedSessionOrder(["claude-a", "claude-b", "claude-c"])

    try await store.deletePinnedSessionOrder(forItemIds: ["claude-b"])

    #expect(try await store.getPinnedSessionOrder() == ["claude-a": 0, "claude-c": 2])
  }

  @Test("Deleting a session's metadata drops its pinned position")
  func deletingMetadataDropsPinnedPosition() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())
    let sessionId = "session-1"

    try await store.setPinnedSessionOrder([
      SidebarSessionItemID.monitored(provider: .claude, sessionId: sessionId),
      "claude-other"
    ])

    try await store.deleteMetadata(for: sessionId)

    #expect(try await store.getPinnedSessionOrder() == ["claude-other": 1])
  }

  @Test("Unpinning leaves the slot behind so re-pinning restores the position")
  func unpinningPreservesTheSlot() async throws {
    let store = try SessionMetadataStore(path: temporaryPinnedOrderDatabasePath())
    let itemId = SidebarSessionItemID.monitored(provider: .claude, sessionId: "session-1")

    try await store.setPinnedSessionOrder([itemId, "claude-other"])
    try await store.setPinned(true, for: "session-1")
    try await store.setPinned(false, for: "session-1")

    #expect(try await store.getPinnedSessionOrder()[itemId] == 0)
  }

  @Test("v13 migration preserves existing metadata on a pre-v13 database")
  func migrationPreservesExistingMetadata() async throws {
    let path = temporaryPinnedOrderDatabasePath()
    let sessionId = "session-1"

    // Build a real database, then rewind it to the pre-v13 schema so the
    // migration runs against rows that already exist — the case that matters.
    let seeded = try SessionMetadataStore(path: path)
    try await seeded.setCustomName("Important session", for: sessionId)
    try await seeded.setPinned(true, for: sessionId)
    try await rewindPastPinnedSessionOrderMigration(at: path)

    let migrated = try SessionMetadataStore(path: path)

    #expect(try await migrated.getCustomName(for: sessionId) == "Important session")
    #expect(try await migrated.getPinnedSessionIds() == Set([sessionId]))
    #expect(try await migrated.getPinnedSessionOrder().isEmpty)

    // And the freshly created table is usable, not just present.
    try await migrated.setPinnedSessionOrder(["claude-\(sessionId)"])
    #expect(try await migrated.getPinnedSessionOrder() == ["claude-\(sessionId)": 0])
  }
}

/// Drops the v13 table and its migration record, leaving every earlier
/// migration and all existing rows in place.
private func rewindPastPinnedSessionOrderMigration(at path: String) throws {
  let queue = try DatabaseQueue(path: path)
  try queue.write { db in
    try db.execute(sql: "DROP TABLE IF EXISTS pinned_session_order")
    try db.execute(
      sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
      arguments: [SessionMetadataStore.MigrationID.createPinnedSessionOrder]
    )
  }
}

private func temporaryPinnedOrderDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_pinned_session_order_\(UUID().uuidString).sqlite")
    .path
}
