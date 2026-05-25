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
  isPinnedSectionCollapsed: Bool = false
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
    id: { $0.id }
  )
  .map(\.id)
}
