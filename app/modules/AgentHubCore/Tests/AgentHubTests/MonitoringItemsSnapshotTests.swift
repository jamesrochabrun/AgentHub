import Foundation
import Testing

@testable import AgentHubCore

private struct SnapshotItem: Identifiable {
  let id: String
  let modulePath: String
  let timestamp: Date
}

@Suite("MonitoringItemsSnapshot")
struct MonitoringItemsSnapshotTests {
  @Test("Single layout exposes only the selected primary item")
  func singleLayoutUsesPrimaryItem() throws {
    let older = SnapshotItem(
      id: "claude-old",
      modulePath: "/tmp/repo-a",
      timestamp: Date(timeIntervalSince1970: 100)
    )
    let newer = SnapshotItem(
      id: "codex-new",
      modulePath: "/tmp/repo-b",
      timestamp: Date(timeIntervalSince1970: 200)
    )

    let snapshot = MonitoringItemsSnapshot(
      items: [older, newer],
      primaryItemID: older.id,
      layoutMode: .single,
      modulePath: { $0.modulePath },
      timestamp: { $0.timestamp }
    )

    #expect(snapshot.effectivePrimaryItemID == older.id)
    #expect(snapshot.visibleItems.map(\.id) == [older.id])
    #expect(snapshot.flatSortedItems.map(\.id) == [older.id])
  }

  @Test("Missing primary falls back to the newest item")
  func missingPrimaryUsesNewestItem() {
    let older = SnapshotItem(
      id: "claude-old",
      modulePath: "/tmp/repo-a",
      timestamp: Date(timeIntervalSince1970: 100)
    )
    let newer = SnapshotItem(
      id: "codex-new",
      modulePath: "/tmp/repo-a",
      timestamp: Date(timeIntervalSince1970: 200)
    )

    let snapshot = MonitoringItemsSnapshot(
      items: [older, newer],
      primaryItemID: "missing",
      layoutMode: .single,
      modulePath: { $0.modulePath },
      timestamp: { $0.timestamp }
    )

    #expect(snapshot.effectivePrimaryItemID == newer.id)
    #expect(snapshot.visibleItems.map(\.id) == [newer.id])
  }

  @Test("Multi-item layouts group by module and sort groups by recent activity")
  func groupsAndSortsVisibleItems() {
    let first = SnapshotItem(
      id: "first",
      modulePath: "/tmp/repo-b",
      timestamp: Date(timeIntervalSince1970: 100)
    )
    let second = SnapshotItem(
      id: "second",
      modulePath: "/tmp/repo-a",
      timestamp: Date(timeIntervalSince1970: 300)
    )
    let third = SnapshotItem(
      id: "third",
      modulePath: "/tmp/repo-a",
      timestamp: Date(timeIntervalSince1970: 200)
    )

    let snapshot = MonitoringItemsSnapshot(
      items: [first, second, third],
      primaryItemID: nil,
      layoutMode: .list,
      modulePath: { $0.modulePath },
      timestamp: { $0.timestamp }
    )

    #expect(snapshot.groupedItems.map(\.modulePath) == ["/tmp/repo-a", "/tmp/repo-b"])
    #expect(snapshot.groupedItems.first?.items.map(\.id) == [second.id, third.id])
    #expect(snapshot.flatSortedItems.map(\.id) == [second.id, third.id, first.id])
  }
}
