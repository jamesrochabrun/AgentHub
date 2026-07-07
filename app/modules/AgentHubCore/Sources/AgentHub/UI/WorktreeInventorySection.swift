import SwiftUI

struct WorktreeInventorySection: View {
  let claudeViewModel: CLISessionsViewModel
  let codexViewModel: CLISessionsViewModel

  @State private var inventoryViewModel: WorktreeInventoryViewModel
  @State private var pendingDeletion: WorktreeSettingsWorktree?
  @State private var isDeleteConfirmationPresented = false
  @State private var deletionFailure: WorktreeInventoryDeletionError?
  @State private var isFailureAlertPresented = false
  @State private var importCoordinator = WorktreeSessionImportCoordinator()

  init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    inventoryService: any GitWorktreeInventoryServiceProtocol = GitWorktreeService(),
    worktreeRemovalService: any GitWorktreeRemovalServiceProtocol = GitWorktreeService()
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self._inventoryViewModel = State(initialValue: WorktreeInventoryViewModel(
      inventoryService: inventoryService,
      removalService: worktreeRemovalService
    ))
  }

  var body: some View {
    Section("Worktrees") {
      let currentSnapshot = inventoryViewModel.snapshot

      if currentSnapshot.modules.isEmpty {
        WorktreeInventoryEmptyView()
      } else {
        VStack(alignment: .leading, spacing: 14) {
          WorktreeInventorySummaryView(snapshot: currentSnapshot)

          if !inventoryViewModel.loadFailuresByRepositoryPath.isEmpty {
            WorktreeInventoryLoadFailureView()
          }

          ForEach(currentSnapshot.modules) { module in
            WorktreeInventoryModuleView(
              module: module,
              isImporting: { importCoordinator.isImporting($0) },
              canShowMore: { importCoordinator.canShowMore($0) },
              onImport: importWorktree,
              onShowMore: showMoreSessions,
              isDeleting: { inventoryViewModel.deletingWorktreePath == $0.path },
              onDelete: requestDelete
            )
          }
        }
        .padding(.vertical, 4)
      }
    }
    .task(id: inventoryReloadID) {
      await reloadInventory()
    }
    .alert("Delete Worktree?", isPresented: $isDeleteConfirmationPresented, presenting: pendingDeletion) { worktree in
      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
      Button(worktree.monitoredSessionCount > 0 ? "Archive & Delete" : "Delete", role: .destructive) {
        delete(worktree)
      }
    } message: { worktree in
      if worktree.monitoredSessionCount > 0 {
        Text("This worktree has \(worktree.monitoredSessionCount) monitored \(worktree.monitoredSessionCount == 1 ? "session" : "sessions"). Continuing will archive those sessions from the side panel and delete the worktree at:\n\(worktree.path)\n\nThis cannot be undone.")
      } else {
        Text("Delete the worktree at:\n\(worktree.path)\n\nThis cannot be undone.")
      }
    }
    .alert("Failed to Delete Worktree", isPresented: $isFailureAlertPresented, presenting: deletionFailure) { failure in
      if failure.isOrphaned, failure.parentRepoPath != nil {
        Button("Prune & Delete", role: .destructive) {
          pruneAndDelete(failure)
        }
      } else {
        Button("Force Delete", role: .destructive) {
          forceDelete(failure)
        }
      }
      Button("Cancel", role: .cancel) {
        clearFailure(failure)
      }
    } message: { failure in
      if failure.isOrphaned, let parentRepoPath = failure.parentRepoPath {
        Text("The worktree at:\n\(failure.worktree.path)\n\nhas no parent repo. You can prune and delete it from:\n\(parentRepoPath)")
      } else {
        Text("\(failure.message)\n\n\"Force Delete\" will remove the worktree even if it contains untracked files.")
      }
    }
  }

  private func requestDelete(_ worktree: WorktreeSettingsWorktree) {
    pendingDeletion = worktree
    isDeleteConfirmationPresented = true
  }

  private func importWorktree(_ worktree: WorktreeSettingsWorktree) {
    Task {
      await importCoordinator.importInitial(
        worktree,
        claudeViewModel: claudeViewModel,
        codexViewModel: codexViewModel
      )
      await reloadInventory()
    }
  }

  private func showMoreSessions(_ worktree: WorktreeSettingsWorktree) {
    Task {
      await importCoordinator.showMore(
        worktree,
        claudeViewModel: claudeViewModel,
        codexViewModel: codexViewModel
      )
      await reloadInventory()
    }
  }

  private func delete(_ worktree: WorktreeSettingsWorktree) {
    pendingDeletion = nil
    Task {
      await delete(worktree, force: false)
    }
  }

  private func forceDelete(_ failure: WorktreeInventoryDeletionError) {
    Task {
      await delete(failure.worktree, force: true)
    }
  }

  private func pruneAndDelete(_ failure: WorktreeInventoryDeletionError) {
    guard let parentRepoPath = failure.parentRepoPath else { return }
    clearFailure(failure)

    Task {
      let succeeded = await inventoryViewModel.deleteOrphaned(
        failure.worktree,
        parentRepoPath: parentRepoPath
      )

      if succeeded {
        completeSuccessfulDeletion(of: failure.worktree)
        await reloadInventory()
      } else {
        showFailure(worktree: failure.worktree)
      }
    }
  }

  private func delete(_ worktree: WorktreeSettingsWorktree, force: Bool) async {
    clearFailure()
    let succeeded = await inventoryViewModel.delete(worktree, force: force)

    if succeeded {
      completeSuccessfulDeletion(of: worktree)
      await reloadInventory()
    } else {
      showFailure(worktree: worktree)
    }
  }

  private func completeSuccessfulDeletion(of worktree: WorktreeSettingsWorktree) {
    claudeViewModel.archiveMonitoredSessions(inWorktreePath: worktree.path)
    codexViewModel.archiveMonitoredSessions(inWorktreePath: worktree.path)
    claudeViewModel.forgetOwnedWorktreePath(worktree.path)
    codexViewModel.forgetOwnedWorktreePath(worktree.path)
    claudeViewModel.refresh()
    codexViewModel.refresh()
  }

  private func showFailure(worktree: WorktreeSettingsWorktree) {
    let error = inventoryViewModel.deletionError ?? WorktreeInventoryDeletionError(
      worktree: worktree,
      message: "The worktree could not be deleted."
    )
    deletionFailure = error
    isFailureAlertPresented = true
  }

  private func clearFailure(_ failure: WorktreeInventoryDeletionError) {
    clearFailure()
    deletionFailure = nil
  }

  private func clearFailure() {
    inventoryViewModel.clearDeletionError()
    deletionFailure = nil
    isFailureAlertPresented = false
  }

  private func reloadInventory() async {
    await inventoryViewModel.reload(
      claudeRepositories: claudeViewModel.selectedRepositories,
      codexRepositories: codexViewModel.selectedRepositories,
      claudeMonitoredSessions: claudeViewModel.monitoredSessions.map(\.session),
      codexMonitoredSessions: codexViewModel.monitoredSessions.map(\.session)
    )
  }

  private var inventoryReloadID: String {
    [
      repositoriesSignature(claudeViewModel.selectedRepositories),
      repositoriesSignature(codexViewModel.selectedRepositories),
      sessionsSignature(claudeViewModel.monitoredSessions.map(\.session)),
      sessionsSignature(codexViewModel.monitoredSessions.map(\.session)),
    ].joined(separator: "|")
  }

  private func repositoriesSignature(_ repositories: [SelectedRepository]) -> String {
    repositories.map { repository in
      let worktrees = repository.worktrees.map { worktree in
        "\(worktree.path):\(worktree.name):\(worktree.isWorktree)"
      }.joined(separator: ",")
      return "\(repository.path)[\(worktrees)]"
    }
    .joined(separator: ";")
  }

  private func sessionsSignature(_ sessions: [CLISession]) -> String {
    sessions.map { session in
      "\(session.id):\(session.projectPath):\(session.isActive)"
    }
    .sorted()
    .joined(separator: ";")
  }
}

private struct WorktreeInventorySummaryView: View {
  let snapshot: WorktreeSettingsSnapshot

  var body: some View {
    HStack(spacing: 8) {
      Label("\(snapshot.modules.count) \(snapshot.modules.count == 1 ? "module" : "modules")", systemImage: "folder")
      Text("·")
        .foregroundStyle(.secondary)
      Text("\(snapshot.worktreeCount) \(snapshot.worktreeCount == 1 ? "worktree" : "worktrees")")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

private struct WorktreeInventoryModuleView: View {
  let module: WorktreeSettingsModule
  let isImporting: (WorktreeSettingsWorktree) -> Bool
  let canShowMore: (WorktreeSettingsWorktree) -> Bool
  let onImport: (WorktreeSettingsWorktree) -> Void
  let onShowMore: (WorktreeSettingsWorktree) -> Void
  let isDeleting: (WorktreeSettingsWorktree) -> Bool
  let onDelete: (WorktreeSettingsWorktree) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "folder.fill")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(module.name)
            .font(.headline)
          Text(module.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        Text("\(module.worktrees.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if module.worktrees.isEmpty {
        Text("No worktrees")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 24)
      } else {
        VStack(spacing: 8) {
          ForEach(module.worktrees) { worktree in
            WorktreeInventoryRow(
              worktree: worktree,
              isImporting: isImporting(worktree),
              canShowMore: canShowMore(worktree),
              onImport: { onImport(worktree) },
              onShowMore: { onShowMore(worktree) },
              isDeleting: isDeleting(worktree),
              onDelete: { onDelete(worktree) }
            )
          }
        }
      }
    }
  }
}

private struct WorktreeInventoryRow: View {
  let worktree: WorktreeSettingsWorktree
  let isImporting: Bool
  let canShowMore: Bool
  let onImport: () -> Void
  let onShowMore: () -> Void
  let isDeleting: Bool
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "arrow.triangle.branch")
          .foregroundStyle(.secondary)
          .frame(width: 18)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 4) {
          Text(worktree.branchName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)

          Text(worktree.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 12)

        deleteControl
      }

      HStack(spacing: 8) {
        WorktreeInventoryBadge(
          title: worktree.isFocusedInAgentHub ? "In AgentHub" : "External",
          systemImage: worktree.isFocusedInAgentHub ? "scope" : "externaldrive",
          isProminent: worktree.isFocusedInAgentHub,
          helpText: worktree.isFocusedInAgentHub
            ? "This worktree is focused in AgentHub, so its sessions can appear in the session list and grouping."
            : "This worktree belongs to a tracked repository, but AgentHub has not focused it for session grouping."
        )

        if worktree.isFocusedInAgentHub, !worktree.providerLabel.isEmpty {
          WorktreeInventoryBadge(
            title: worktree.providerLabel,
            systemImage: "terminal",
            isProminent: false,
            helpText: "Providers with AgentHub session history for this worktree."
          )
        }

        diskSizeView

        Spacer(minLength: 12)

        sessionImportControl
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.04))
    )
  }

  @ViewBuilder
  private var diskSizeView: some View {
    if let diskSizeBytes = worktree.diskSizeBytes {
      WorktreeInventoryBadge(
        title: ByteCountFormatter.string(fromByteCount: diskSizeBytes, countStyle: .file),
        systemImage: "externaldrive",
        isProminent: false,
        helpText: "Approximate disk space reclaimed by deleting this worktree."
      )
    } else {
      ProgressView()
        .scaleEffect(0.55)
        .frame(width: 18, height: 18)
        .help("Calculating worktree size")
    }
  }

  @ViewBuilder
  private var sessionImportControl: some View {
    if worktree.isFocusedInAgentHub {
      HStack(spacing: 10) {
        Label(displayedSessionLabel, systemImage: worktree.activeMonitoredSessionCount > 0 ? "circle.fill" : "circle")
          .font(.caption)
          .foregroundStyle(worktree.activeMonitoredSessionCount > 0 ? .green : .secondary)
          .help("\(worktree.monitoredSessionCount) displayed \(worktree.monitoredSessionCount == 1 ? "session" : "sessions")")

        if isImporting {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 24, height: 24)
        } else if canShowMore {
          Button("Load 3 more", systemImage: "plus.circle", action: onShowMore)
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Load the next 3 sessions")
        }
      }
    } else if isImporting {
      ProgressView()
        .scaleEffect(0.7)
        .frame(width: 28, height: 28)
    } else {
      Button("Import", systemImage: "tray.and.arrow.down", action: onImport)
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Import worktree")
    }
  }

  @ViewBuilder
  private var deleteControl: some View {
    if isDeleting {
      ProgressView()
        .scaleEffect(0.7)
        .frame(width: 28, height: 28)
    } else {
      Button("Delete worktree \(worktree.branchName)", systemImage: "trash", action: onDelete)
        .labelStyle(.iconOnly)
        .font(.system(size: 13))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Delete worktree")
    }
  }

  private var displayedSessionLabel: String {
    "\(worktree.monitoredSessionCount) \(worktree.monitoredSessionCount == 1 ? "session" : "sessions") displayed"
  }
}

private struct WorktreeInventoryBadge: View {
  let title: String
  let systemImage: String
  let isProminent: Bool
  let helpText: String

  @State private var isHelpPresented = false

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption)
      .labelStyle(.titleAndIcon)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .foregroundStyle(isProminent ? .primary : .secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.primary.opacity(isProminent ? 0.08 : 0.05))
      )
      .contentShape(RoundedRectangle(cornerRadius: 5))
      .help(helpText)
      .onHover { isHovering in
        isHelpPresented = isHovering
      }
      .popover(isPresented: $isHelpPresented, arrowEdge: .top) {
        Text(helpText)
          .font(.caption)
          .foregroundStyle(.primary)
          .padding(10)
          .frame(width: 240, alignment: .leading)
      }
  }
}

private struct WorktreeInventoryLoadFailureView: View {
  var body: some View {
    Label("Some git worktrees could not be loaded", systemImage: "exclamationmark.triangle")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

private struct WorktreeInventoryEmptyView: View {
  var body: some View {
    Label("No modules added to the sessions side panel", systemImage: "folder")
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.vertical, 4)
  }
}
