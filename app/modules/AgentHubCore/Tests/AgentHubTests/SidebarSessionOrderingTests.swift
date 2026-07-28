import Foundation
import Testing

@testable import AgentHubCore

@Suite("Sidebar session ordering")
struct SidebarSessionOrderingTests {
  @Test("Repo grouping flattens by module order instead of global timestamp")
  func repoGroupingFlattensByModuleOrder() {
    let repoA = SelectedRepository(
      path: "/tmp/RepoA",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/RepoA", isWorktree: false),
        WorktreeBranch(name: "feature", path: "/tmp/RepoA-feature", isWorktree: true)
      ]
    )
    let repoB = SelectedRepository(path: "/tmp/RepoB")

    let items = [
      item("b-newest", projectPath: "/tmp/RepoB", timestamp: 400),
      item("a-worktree", projectPath: "/tmp/RepoA-feature", timestamp: 300),
      item("a-main", projectPath: "/tmp/RepoA", timestamp: 100)
    ]

    let ids = flattenedIDs(
      items,
      repositories: [repoA, repoB],
      groupMode: .repo,
      worktreeDisplayMode: .parent
    )

    #expect(ids == ["a-worktree", "a-main", "b-newest"])
  }

  @Test("Separate worktree module mode flattens worktree sections independently")
  func separateWorktreeModeFlattensWorktreeSections() {
    let repoA = SelectedRepository(
      path: "/tmp/RepoA",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/RepoA", isWorktree: false),
        WorktreeBranch(name: "feature", path: "/tmp/RepoA-feature", isWorktree: true)
      ]
    )
    let repoB = SelectedRepository(path: "/tmp/RepoB")

    let items = [
      item("b-newest", projectPath: "/tmp/RepoB", timestamp: 400),
      item("a-worktree", projectPath: "/tmp/RepoA-feature", timestamp: 300),
      item("a-main", projectPath: "/tmp/RepoA", timestamp: 100)
    ]

    let ids = flattenedIDs(
      items,
      repositories: [repoA, repoB],
      groupMode: .repo,
      worktreeDisplayMode: .separateModules
    )

    #expect(ids == ["a-main", "a-worktree", "b-newest"])
  }

  @Test("Repository sections keep root and worktree modules as siblings")
  func repositorySectionsKeepRootAndWorktreeModulesAsSiblings() {
    let repoA = SelectedRepository(
      path: "/tmp/RepoA",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/RepoA", isWorktree: false),
        WorktreeBranch(name: "feature", path: "/tmp/RepoA-feature", isWorktree: true)
      ]
    )
    let repoB = SelectedRepository(path: "/tmp/RepoB")

    let sections = SidebarSessionOrdering.repositoryModuleSections(
      from: [
        item("b", projectPath: "/tmp/RepoB", timestamp: 300),
        item("a-worktree", projectPath: "/tmp/RepoA-feature", timestamp: 200),
        item("a-main", projectPath: "/tmp/RepoA", timestamp: 100)
      ],
      repositories: [repoA, repoB],
      worktreeDisplayMode: .separateModules,
      isPinned: { $0.isPinned },
      projectPath: { $0.projectPath },
      timestamp: { $0.timestamp },
      id: { $0.id }
    )

    #expect(sections.map(\.id) == ["/tmp/RepoA", "/tmp/RepoB"])
    #expect(sections[0].groups.map(\.id) == ["/tmp/RepoA", "/tmp/RepoA-feature"])
    #expect(sections[1].groups.map(\.id) == ["/tmp/RepoB"])
  }

  @Test("Status grouping flattens by status section order")
  func statusGroupingFlattensByStatusOrder() {
    let items = [
      item("idle-newest", timestamp: 500, status: .idle),
      item("ready", timestamp: 400, status: .waitingForUser),
      item("working", timestamp: 300, status: .thinking),
      item("approval", timestamp: 200, status: .awaitingApproval(tool: "Edit"))
    ]

    let ids = flattenedIDs(items, groupMode: .status)

    #expect(ids == ["approval", "working", "ready", "idle-newest"])
  }

  @Test("Pinned sessions stay first before the active grouping")
  func pinnedSessionsStayFirst() {
    let items = [
      item("repo-item", projectPath: "/tmp/Repo", timestamp: 500),
      item("pinned-old", projectPath: "/tmp/Repo", timestamp: 100, isPinned: true)
    ]

    let ids = flattenedIDs(
      items,
      repositories: [SelectedRepository(path: "/tmp/Repo")],
      groupMode: .repo
    )

    #expect(ids == ["pinned-old", "repo-item"])
  }

  @Test("Collapsed sidebar groups are skipped by keyboard navigation order")
  func collapsedGroupsAreSkipped() {
    let repoA = SelectedRepository(path: "/tmp/RepoA")
    let repoB = SelectedRepository(path: "/tmp/RepoB")
    let items = [
      item("a", projectPath: "/tmp/RepoA", timestamp: 200),
      item("b", projectPath: "/tmp/RepoB", timestamp: 100)
    ]

    let ids = flattenedIDs(
      items,
      repositories: [repoA, repoB],
      groupMode: .repo,
      collapsedProjectGroups: ["/tmp/RepoA"]
    )

    #expect(ids == ["b"])
  }

  // MARK: - Manual pinned order

  @Test("Manual pinned order overrides the activity sort")
  func manualPinnedOrderOverridesActivitySort() {
    let items = [
      item("newest", timestamp: 500, isPinned: true),
      item("middle", timestamp: 300, isPinned: true),
      item("oldest", timestamp: 100, isPinned: true)
    ]

    let ids = pinnedIDs(items, manualOrder: ["oldest": 0, "newest": 1, "middle": 2])

    #expect(ids == ["oldest", "newest", "middle"])
  }

  @Test("Freshly pinned sessions sort after arranged ones, by activity")
  func unorderedPinnedItemsFallInAfterArrangedOnes() {
    let items = [
      item("arranged-second", timestamp: 100, isPinned: true),
      item("just-pinned-old", timestamp: 200, isPinned: true),
      item("arranged-first", timestamp: 300, isPinned: true),
      item("just-pinned-new", timestamp: 400, isPinned: true)
    ]

    let ids = pinnedIDs(items, manualOrder: ["arranged-first": 0, "arranged-second": 1])

    #expect(ids == ["arranged-first", "arranged-second", "just-pinned-new", "just-pinned-old"])
  }

  @Test("Keyboard navigation order follows the manual pinned order")
  func flattenedOrderFollowsManualPinnedOrder() {
    let items = [
      item("pinned-newest", timestamp: 500, isPinned: true),
      item("pinned-oldest", timestamp: 100, isPinned: true),
      item("unpinned", timestamp: 400)
    ]

    let ids = flattenedIDs(
      items,
      groupMode: .repo,
      manualOrder: ["pinned-oldest": 0, "pinned-newest": 1]
    )

    #expect(ids == ["pinned-oldest", "pinned-newest", "unpinned"])
  }

  @Test("Manual order is ignored for sessions that are not pinned")
  func manualOrderDoesNotPromoteUnpinnedSessions() {
    let items = [
      item("pinned", timestamp: 100, isPinned: true),
      item("unpinned", timestamp: 500)
    ]

    let ids = pinnedIDs(items, manualOrder: ["unpinned": 0, "pinned": 1])

    #expect(ids == ["pinned"])
  }

  // MARK: - Reorder math

  @Test("Dropping in a row's lower half inserts the dragged row after it")
  func dropPlacementMovesRowDown() {
    let result = SidebarSessionOrdering.reorderedIDs(
      ["a", "b", "c"],
      movingID: "a",
      targetID: "b",
      placement: .after
    )

    #expect(result == ["b", "a", "c"])
  }

  @Test("Dropping in the first row's upper half moves the dragged row to the top")
  func dropPlacementMovesRowToTop() {
    let result = SidebarSessionOrdering.reorderedIDs(
      ["a", "b", "c"],
      movingID: "c",
      targetID: "a",
      placement: .before
    )

    #expect(result == ["c", "a", "b"])
  }

  @Test("Dropping in the last row's lower half moves the dragged row to the end")
  func dropPlacementMovesRowToEnd() {
    let result = SidebarSessionOrdering.reorderedIDs(
      ["a", "b", "c"],
      movingID: "a",
      targetID: "c",
      placement: .after
    )

    #expect(result == ["b", "c", "a"])
  }

  @Test("A placement that resolves to the current slot is a no-op")
  func unchangedDropPlacementReturnsNil() {
    #expect(SidebarSessionOrdering.reorderedIDs(
      ["a", "b", "c"],
      movingID: "b",
      targetID: "a",
      placement: .after
    ) == nil)
  }

  @Test("Reorder rejects unknown rows and self-targeting")
  func reorderRejectsInvalidInput() {
    #expect(SidebarSessionOrdering.reorderedIDs(
      ["a", "b"],
      movingID: "missing",
      targetID: "a",
      placement: .before
    ) == nil)

    #expect(SidebarSessionOrdering.reorderedIDs(
      ["a", "b"],
      movingID: "a",
      targetID: "missing",
      placement: .after
    ) == nil)

    #expect(SidebarSessionOrdering.reorderedIDs(
      ["a", "b"],
      movingID: "a",
      targetID: "a",
      placement: .after
    ) == nil)
  }

  @Test("The same target placement stays stable after rows animate around it")
  func reorderDoesNotOscillateAfterLayoutUpdate() {
    let firstResult = SidebarSessionOrdering.reorderedIDs(
      ["a", "b", "c"],
      movingID: "a",
      targetID: "b",
      placement: .after
    )
    #expect(firstResult == ["b", "a", "c"])

    let settledResult = SidebarSessionOrdering.reorderedIDs(
      firstResult ?? [],
      movingID: "a",
      targetID: "b",
      placement: .after
    )
    #expect(settledResult == nil)
  }

  @Test("Crossing back over a target midpoint reverses the previous move")
  func reorderCanReverseDirection() {
    let result = SidebarSessionOrdering.reorderedIDs(
      ["b", "a", "c"],
      movingID: "a",
      targetID: "b",
      placement: .before
    )

    #expect(result == ["a", "b", "c"])
  }

  @Test("Next ID indexes through the flattened order without wrapping")
  func nextIDIndexesThroughFlattenedOrder() {
    let ids = ["first", "second", "third"]

    #expect(SidebarSessionOrdering.nextID(in: ids, currentID: nil, direction: .forward) == "first")
    #expect(SidebarSessionOrdering.nextID(in: ids, currentID: "first", direction: .forward) == "second")
    #expect(SidebarSessionOrdering.nextID(in: ids, currentID: "third", direction: .forward) == "third")
    #expect(SidebarSessionOrdering.nextID(in: ids, currentID: "third", direction: .backward) == "second")
  }
}

private struct SidebarTestItem {
  let id: String
  let projectPath: String
  let timestamp: Date
  let status: SessionStatus?
  let isPinned: Bool
}

private func item(
  _ id: String,
  projectPath: String = "/tmp/Repo",
  timestamp: TimeInterval,
  status: SessionStatus? = nil,
  isPinned: Bool = false
) -> SidebarTestItem {
  SidebarTestItem(
    id: id,
    projectPath: projectPath,
    timestamp: Date(timeIntervalSince1970: timestamp),
    status: status,
    isPinned: isPinned
  )
}

private func flattenedIDs(
  _ items: [SidebarTestItem],
  repositories: [SelectedRepository] = [SelectedRepository(path: "/tmp/Repo")],
  groupMode: SidebarGroupMode,
  worktreeDisplayMode: WorktreeDisplayMode = .parent,
  collapsedProjectGroups: Set<String> = [],
  collapsedStatusGroups: Set<StatusGroupCategory> = [],
  isPinnedSectionCollapsed: Bool = false,
  manualOrder: [String: Int] = [:]
) -> [String] {
  SidebarSessionOrdering.flattenedItems(
    from: items,
    repositories: repositories,
    groupMode: groupMode,
    worktreeDisplayMode: worktreeDisplayMode,
    collapsedProjectGroups: collapsedProjectGroups,
    collapsedStatusGroups: collapsedStatusGroups,
    isPinnedSectionCollapsed: isPinnedSectionCollapsed,
    isPinned: { $0.isPinned },
    projectPath: { $0.projectPath },
    status: { $0.status },
    timestamp: { $0.timestamp },
    id: { $0.id },
    manualOrder: { manualOrder[$0.id] }
  )
  .map(\.id)
}

private func pinnedIDs(
  _ items: [SidebarTestItem],
  manualOrder: [String: Int] = [:]
) -> [String] {
  SidebarSessionOrdering.pinnedItems(
    from: items,
    isPinned: { $0.isPinned },
    timestamp: { $0.timestamp },
    id: { $0.id },
    manualOrder: { manualOrder[$0.id] }
  )
  .map(\.id)
}
