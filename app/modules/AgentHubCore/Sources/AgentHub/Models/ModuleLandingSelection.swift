//
//  ModuleLandingSelection.swift
//  AgentHub
//
enum ModuleLandingSelection {
  static func activeModulePath(
    selectedPath: String?,
    repositories: [SelectedRepository],
    itemProjectPaths: [String],
    mode: WorktreeDisplayMode = .parent
  ) -> String? {
    guard let selectedPath else { return nil }
    guard WorktreeModuleResolver.modulePaths(for: repositories, mode: mode).contains(selectedPath) else { return nil }

    let hasItems = itemProjectPaths.contains { itemPath in
      WorktreeModuleResolver.modulePath(
        for: itemPath,
        repositories: repositories,
        mode: mode
      ) == selectedPath
    }
    return hasItems ? nil : selectedPath
  }
}
