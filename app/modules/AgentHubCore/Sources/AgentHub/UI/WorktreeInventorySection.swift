import SwiftUI

struct WorktreeInventorySection: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel

  @State private var pendingDeletion: WorktreeSettingsWorktree?
  @State private var isDeleteConfirmationPresented = false
  @State private var deletionFailure: WorktreeSettingsDeletionFailure?
  @State private var isFailureAlertPresented = false

  var body: some View {
    Section("Worktrees") {
      let currentSnapshot = snapshot

      if currentSnapshot.modules.isEmpty {
        WorktreeInventoryEmptyView()
      } else {
        VStack(alignment: .leading, spacing: 14) {
          WorktreeInventorySummaryView(snapshot: currentSnapshot)

          ForEach(currentSnapshot.modules) { module in
            WorktreeInventoryModuleView(
              module: module,
              isDeleting: { isDeletingWorktree(at: $0.path) },
              onDelete: requestDelete
            )
          }
        }
        .padding(.vertical, 4)
      }
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
      if failure.error.isOrphaned, failure.error.parentRepoPath != nil {
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
      if failure.error.isOrphaned, let parentRepoPath = failure.error.parentRepoPath {
        Text("The worktree at:\n\(failure.error.worktree.path)\n\nhas no parent repo. You can prune and delete it from:\n\(parentRepoPath)")
      } else {
        Text("\(failure.error.message)\n\n\"Force Delete\" will remove the worktree even if it contains untracked files.")
      }
    }
  }

  private var snapshot: WorktreeSettingsSnapshot {
    WorktreeSettingsInventoryBuilder.snapshot(
      claudeRepositories: claudeViewModel.selectedRepositories,
      codexRepositories: codexViewModel.selectedRepositories,
      claudeMonitoredSessions: claudeViewModel.monitoredSessions.map(\.session),
      codexMonitoredSessions: codexViewModel.monitoredSessions.map(\.session)
    )
  }

  private func requestDelete(_ worktree: WorktreeSettingsWorktree) {
    pendingDeletion = worktree
    isDeleteConfirmationPresented = true
  }

  private func delete(_ worktree: WorktreeSettingsWorktree) {
    pendingDeletion = nil
    Task {
      await delete(worktree, force: false)
    }
  }

  private func forceDelete(_ failure: WorktreeSettingsDeletionFailure) {
    Task {
      await delete(failure.worktree, force: true)
    }
  }

  private func pruneAndDelete(_ failure: WorktreeSettingsDeletionFailure) {
    guard let parentRepoPath = failure.error.parentRepoPath else { return }
    clearFailure(failure)

    Task {
      let viewModel = viewModel(for: failure.providerKind)
      let succeeded = await viewModel.deleteOrphanedWorktree(
        failure.error.worktree,
        parentRepoPath: parentRepoPath
      )

      if succeeded {
        completeSuccessfulDeletion(of: failure.worktree)
      } else {
        showFailure(from: viewModel, worktree: failure.worktree)
      }
    }
  }

  private func delete(_ worktree: WorktreeSettingsWorktree, force: Bool) async {
    clearFailure(providerKind: worktree.deletionProviderKind)
    let viewModel = viewModel(for: worktree.deletionProviderKind)
    let succeeded = await viewModel.deleteWorktree(worktree.worktree, force: force)

    if succeeded {
      completeSuccessfulDeletion(of: worktree)
    } else {
      showFailure(from: viewModel, worktree: worktree)
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

  private func showFailure(from viewModel: CLISessionsViewModel, worktree: WorktreeSettingsWorktree) {
    let error = viewModel.worktreeDeletionError ?? CLISessionsViewModel.WorktreeDeletionError(
      worktree: worktree.worktree,
      message: "The worktree could not be deleted."
    )
    deletionFailure = WorktreeSettingsDeletionFailure(
      providerKind: viewModel.providerKind,
      worktree: worktree,
      error: error
    )
    isFailureAlertPresented = true
  }

  private func clearFailure(_ failure: WorktreeSettingsDeletionFailure) {
    clearFailure(providerKind: failure.providerKind)
    deletionFailure = nil
  }

  private func clearFailure(providerKind: SessionProviderKind) {
    viewModel(for: providerKind).clearWorktreeDeletionError()
    deletionFailure = nil
    isFailureAlertPresented = false
  }

  private func viewModel(for providerKind: SessionProviderKind) -> CLISessionsViewModel {
    switch providerKind {
    case .claude:
      return claudeViewModel
    case .codex:
      return codexViewModel
    }
  }

  private func isDeletingWorktree(at path: String) -> Bool {
    claudeViewModel.deletingWorktreePath == path || codexViewModel.deletingWorktreePath == path
  }
}

private struct WorktreeSettingsDeletionFailure {
  let providerKind: SessionProviderKind
  let worktree: WorktreeSettingsWorktree
  let error: CLISessionsViewModel.WorktreeDeletionError
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
        VStack(spacing: 6) {
          ForEach(module.worktrees) { worktree in
            WorktreeInventoryRow(
              worktree: worktree,
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
  let isDeleting: Bool
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "arrow.triangle.branch")
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(worktree.branchName)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)

          Text(worktree.providerLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            )
        }

        Text(worktree.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 8)

      if worktree.monitoredSessionCount > 0 {
        Label("\(worktree.monitoredSessionCount)", systemImage: worktree.activeMonitoredSessionCount > 0 ? "circle.fill" : "circle")
          .font(.caption)
          .foregroundStyle(worktree.activeMonitoredSessionCount > 0 ? .green : .secondary)
          .help("\(worktree.monitoredSessionCount) monitored \(worktree.monitoredSessionCount == 1 ? "session" : "sessions")")
      }

      if isDeleting {
        ProgressView()
          .scaleEffect(0.7)
          .frame(width: 28, height: 28)
      } else {
        Button(action: onDelete) {
          Image(systemName: "trash")
            .font(.system(size: 13))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Delete worktree")
        .accessibilityLabel("Delete worktree \(worktree.branchName)")
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.04))
    )
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
