import Foundation
import Testing

@testable import AgentHubCore

private struct SnapshotItem: Identifiable {
  let id: String
  let timestamp: Date
}

@Suite("MonitoringItemsSnapshot")
struct MonitoringItemsSnapshotTests {
  @Test("Single layout exposes only the selected primary item")
  func singleLayoutUsesPrimaryItem() throws {
    let older = SnapshotItem(
      id: "claude-old",
      timestamp: Date(timeIntervalSince1970: 100)
    )
    let newer = SnapshotItem(
      id: "codex-new",
      timestamp: Date(timeIntervalSince1970: 200)
    )

    let snapshot = MonitoringItemsSnapshot(
      items: [older, newer],
      primaryItemID: older.id,
      timestamp: { $0.timestamp }
    )

    #expect(snapshot.effectivePrimaryItemID == older.id)
    #expect(snapshot.visibleItems.map(\.id) == [older.id])
  }

  @Test("Missing primary falls back to the newest item")
  func missingPrimaryUsesNewestItem() {
    let older = SnapshotItem(
      id: "claude-old",
      timestamp: Date(timeIntervalSince1970: 100)
    )
    let newer = SnapshotItem(
      id: "codex-new",
      timestamp: Date(timeIntervalSince1970: 200)
    )

    let snapshot = MonitoringItemsSnapshot(
      items: [older, newer],
      primaryItemID: "missing",
      timestamp: { $0.timestamp }
    )

    #expect(snapshot.effectivePrimaryItemID == newer.id)
    #expect(snapshot.visibleItems.map(\.id) == [newer.id])
  }

  @Test("All item IDs remain available for selection and pruning")
  func itemIDsIncludeEveryItem() {
    let first = SnapshotItem(
      id: "first",
      timestamp: Date(timeIntervalSince1970: 100)
    )
    let second = SnapshotItem(
      id: "second",
      timestamp: Date(timeIntervalSince1970: 300)
    )
    let third = SnapshotItem(
      id: "third",
      timestamp: Date(timeIntervalSince1970: 200)
    )

    let snapshot = MonitoringItemsSnapshot(
      items: [first, second, third],
      primaryItemID: nil,
      timestamp: { $0.timestamp }
    )

    #expect(snapshot.effectivePrimaryItemID == second.id)
    #expect(snapshot.visibleItems.map(\.id) == [second.id])
    #expect(snapshot.itemIDs == [first.id, second.id, third.id])
  }
}
