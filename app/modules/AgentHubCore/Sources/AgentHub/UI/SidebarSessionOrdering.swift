//
//  SidebarSessionOrdering.swift
//  AgentHub
//

import Foundation

enum SidebarGroupMode: String, CaseIterable {
  case repo = "Repo"
  case status = "Status"
}

enum StatusGroupCategory: String, CaseIterable, Identifiable {
  case needsAttention = "Needs Attention"
  case working = "Working"
  case ready = "Ready"
  case idle = "Idle"

  var id: String { rawValue }

  static func category(for status: SessionStatus?) -> StatusGroupCategory {
    switch status {
    case .thinking, .executingTool:
      return .working
    case .waitingForUser:
      return .ready
    case .awaitingApproval:
      return .needsAttention
    case .idle, .none:
      return .idle
    }
  }
}

enum SidebarSessionNavigationDirection {
  case forward
  case backward
}

struct SidebarSessionGroup<Item>: Identifiable {
  let id: String
  let displayName: String
  let items: [Item]
}

struct SidebarRepositoryModuleSection<Item>: Identifiable {
  let id: String
  let displayName: String
  let groups: [SidebarSessionGroup<Item>]
}

enum SidebarSessionOrdering {
  /// The pinned section, in the order the user sees it.
  ///
  /// Pinned rows are the only ones the user can drag, so they are the only ones
  /// with a manual order. Rows the user has positioned come first in that
  /// order; rows that have never been positioned (a freshly pinned session)
  /// keep the activity sort and land after them, so pinning something new never
  /// disturbs an arrangement the user built by hand.
  static func pinnedItems<Item>(
    from items: [Item],
    isPinned: (Item) -> Bool,
    timestamp: (Item) -> Date,
    id: (Item) -> String,
    manualOrder: (Item) -> Int? = { _ in nil }
  ) -> [Item] {
    items
      .filter(isPinned)
      .sorted { lhs, rhs in
        switch (manualOrder(lhs), manualOrder(rhs)) {
        case let (lhsIndex?, rhsIndex?):
          if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
          return orderedByActivity(lhs, rhs, timestamp: timestamp, id: id)
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          return orderedByActivity(lhs, rhs, timestamp: timestamp, id: id)
        }
      }
  }

  static func moduleGroups<Item>(
    from items: [Item],
    repositories: [SelectedRepository],
    worktreeDisplayMode: WorktreeDisplayMode,
    isPinned: (Item) -> Bool,
    projectPath: (Item) -> String,
    timestamp: (Item) -> Date,
    id: (Item) -> String
  ) -> [SidebarSessionGroup<Item>] {
    let unpinnedItems = items.filter { !isPinned($0) }
    var itemsByModule: [String: [Item]] = [:]

    for item in unpinnedItems {
      let key = WorktreeModuleResolver.modulePath(
        for: projectPath(item),
        repositories: repositories,
        mode: worktreeDisplayMode
      )
      itemsByModule[key, default: []].append(item)
    }

    var groups: [SidebarSessionGroup<Item>] = []
    var handledKeys: Set<String> = []

    for modulePath in WorktreeModuleResolver.modulePaths(for: repositories, mode: worktreeDisplayMode) {
      groups.append(SidebarSessionGroup(
        id: modulePath,
        displayName: URL(fileURLWithPath: modulePath).lastPathComponent,
        items: sortedByActivity(itemsByModule[modulePath] ?? [], timestamp: timestamp, id: id)
      ))
      handledKeys.insert(modulePath)
    }

    let orphanKeys = itemsByModule.keys
      .filter { !handledKeys.contains($0) }
      .sorted()

    for key in orphanKeys {
      groups.append(SidebarSessionGroup(
        id: key,
        displayName: URL(fileURLWithPath: key).lastPathComponent,
        items: sortedByActivity(itemsByModule[key] ?? [], timestamp: timestamp, id: id)
      ))
    }

    return groups
  }

  static func repositoryModuleSections<Item>(
    from items: [Item],
    repositories: [SelectedRepository],
    worktreeDisplayMode: WorktreeDisplayMode,
    isPinned: (Item) -> Bool,
    projectPath: (Item) -> String,
    timestamp: (Item) -> Date,
    id: (Item) -> String
  ) -> [SidebarRepositoryModuleSection<Item>] {
    let groups = moduleGroups(
      from: items,
      repositories: repositories,
      worktreeDisplayMode: worktreeDisplayMode,
      isPinned: isPinned,
      projectPath: projectPath,
      timestamp: timestamp,
      id: id
    )
    let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    var handledGroupIDs: Set<String> = []
    var sections: [SidebarRepositoryModuleSection<Item>] = []

    for repository in WorktreeModuleResolver.mergedRepositories(repositories) {
      let repositoryPath = WorktreeModuleResolver.normalizedDirectoryPath(repository.path)
      let modulePaths = WorktreeModuleResolver.modulePaths(
        for: [repository],
        mode: worktreeDisplayMode
      )
      let sectionGroups = modulePaths.compactMap { groupsByID[$0] }
      guard !sectionGroups.isEmpty else { continue }

      handledGroupIDs.formUnion(sectionGroups.map(\.id))
      sections.append(SidebarRepositoryModuleSection(
        id: repositoryPath,
        displayName: URL(fileURLWithPath: repositoryPath).lastPathComponent,
        groups: sectionGroups
      ))
    }

    let orphanGroups = groups.filter { !handledGroupIDs.contains($0.id) }
    for group in orphanGroups {
      sections.append(SidebarRepositoryModuleSection(
        id: group.id,
        displayName: group.displayName,
        groups: [group]
      ))
    }

    return sections
  }

  static func statusGroups<Item>(
    from items: [Item],
    isPinned: (Item) -> Bool,
    status: (Item) -> SessionStatus?,
    timestamp: (Item) -> Date,
    id: (Item) -> String
  ) -> [StatusGroupCategory: [Item]] {
    var result: [StatusGroupCategory: [Item]] = [:]

    for item in items where !isPinned(item) {
      let category = StatusGroupCategory.category(for: status(item))
      result[category, default: []].append(item)
    }

    for key in result.keys {
      result[key] = sortedByActivity(result[key] ?? [], timestamp: timestamp, id: id)
    }

    return result
  }

  static func flattenedItems<Item>(
    from items: [Item],
    repositories: [SelectedRepository],
    groupMode: SidebarGroupMode,
    worktreeDisplayMode: WorktreeDisplayMode,
    collapsedProjectGroups: Set<String>,
    collapsedStatusGroups: Set<StatusGroupCategory>,
    isPinnedSectionCollapsed: Bool,
    isPinned: (Item) -> Bool,
    projectPath: (Item) -> String,
    status: (Item) -> SessionStatus?,
    timestamp: (Item) -> Date,
    id: (Item) -> String,
    manualOrder: (Item) -> Int? = { _ in nil }
  ) -> [Item] {
    var result: [Item] = []

    if !isPinnedSectionCollapsed {
      result.append(contentsOf: pinnedItems(
        from: items,
        isPinned: isPinned,
        timestamp: timestamp,
        id: id,
        manualOrder: manualOrder
      ))
    }

    switch groupMode {
    case .repo:
      let groups = moduleGroups(
        from: items,
        repositories: repositories,
        worktreeDisplayMode: worktreeDisplayMode,
        isPinned: isPinned,
        projectPath: projectPath,
        timestamp: timestamp,
        id: id
      )

      for group in groups where !collapsedProjectGroups.contains(group.id) {
        result.append(contentsOf: group.items)
      }

    case .status:
      let groups = statusGroups(
        from: items,
        isPinned: isPinned,
        status: status,
        timestamp: timestamp,
        id: id
      )

      for category in StatusGroupCategory.allCases where !collapsedStatusGroups.contains(category) {
        result.append(contentsOf: groups[category] ?? [])
      }
    }

    return result
  }

  /// Repositions one pinned row before or after the row under the pointer.
  ///
  /// The dragged row is removed before the target index is calculated, so the
  /// operation remains correct regardless of which direction the row moves.
  /// Returns `nil` for invalid inputs and unchanged placements.
  static func reorderedIDs(
    _ ids: [String],
    movingID: String,
    targetID: String,
    placement: PinnedSessionDropPlacement
  ) -> [String]? {
    guard movingID != targetID,
          ids.contains(movingID),
          ids.contains(targetID)
    else { return nil }

    let remainingIDs = ids.filter { $0 != movingID }
    guard let targetIndex = remainingIDs.firstIndex(of: targetID) else {
      return nil
    }

    var reorderedIDs = remainingIDs
    let insertionIndex = placement == .before ? targetIndex : targetIndex + 1
    reorderedIDs.insert(movingID, at: insertionIndex)

    return reorderedIDs == ids ? nil : reorderedIDs
  }

  static func nextID(
    in orderedIDs: [String],
    currentID: String?,
    direction: SidebarSessionNavigationDirection
  ) -> String? {
    guard !orderedIDs.isEmpty else { return nil }
    guard let currentID,
          let currentIndex = orderedIDs.firstIndex(of: currentID) else {
      return orderedIDs.first
    }

    let newIndex: Int
    switch direction {
    case .forward:
      newIndex = min(currentIndex + 1, orderedIDs.count - 1)
    case .backward:
      newIndex = max(currentIndex - 1, 0)
    }
    return orderedIDs[newIndex]
  }

  private static func sortedByActivity<Item>(
    _ items: [Item],
    timestamp: (Item) -> Date,
    id: (Item) -> String
  ) -> [Item] {
    items.sorted { orderedByActivity($0, $1, timestamp: timestamp, id: id) }
  }

  private static func orderedByActivity<Item>(
    _ lhs: Item,
    _ rhs: Item,
    timestamp: (Item) -> Date,
    id: (Item) -> String
  ) -> Bool {
    let lhsTimestamp = timestamp(lhs)
    let rhsTimestamp = timestamp(rhs)
    if lhsTimestamp != rhsTimestamp {
      return lhsTimestamp > rhsTimestamp
    }
    return id(lhs) < id(rhs)
  }
}
