//
//  ModuleLandingSelection.swift
//  AgentHub
//
enum ModuleLandingSelection {
  static func activeModulePath(
    selectedPath: String?,
    repositories: [SelectedRepository],
    itemProjectPaths: [String]
  ) -> String? {
    guard let selectedPath else { return nil }
    guard repositories.contains(where: { $0.path == selectedPath }) else { return nil }

    let hasItems = itemProjectPaths.contains { itemPath in
      parentModulePath(for: itemPath, repositories: repositories) == selectedPath
    }
    return hasItems ? nil : selectedPath
  }

  private static func parentModulePath(
    for itemPath: String,
    repositories: [SelectedRepository]
  ) -> String {
    for repository in repositories {
      if repository.path == itemPath {
        return repository.path
      }

      if repository.worktrees.contains(where: { $0.path == itemPath }) {
        return repository.path
      }
    }

    return itemPath
  }
}
