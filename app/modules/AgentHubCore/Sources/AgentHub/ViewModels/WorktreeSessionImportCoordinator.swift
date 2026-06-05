import Foundation

@MainActor
@Observable
final class WorktreeSessionImportCoordinator {
  private let pageSize: Int
  private(set) var importingWorktreePaths: Set<String> = []
  private(set) var hasMoreByWorktreePath: [String: Bool] = [:]

  init(pageSize: Int = 3) {
    self.pageSize = pageSize
  }

  func isImporting(_ worktree: WorktreeSettingsWorktree) -> Bool {
    importingWorktreePaths.contains(normalized(worktree.path))
  }

  func canShowMore(_ worktree: WorktreeSettingsWorktree) -> Bool {
    hasMoreByWorktreePath[normalized(worktree.path)] ?? true
  }

  func importInitial(
    _ worktree: WorktreeSettingsWorktree,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) async {
    await importNextPage(
      worktree,
      shouldFocusWorktree: true,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )
  }

  func showMore(
    _ worktree: WorktreeSettingsWorktree,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) async {
    await importNextPage(
      worktree,
      shouldFocusWorktree: true,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )
  }

  private func importNextPage(
    _ worktree: WorktreeSettingsWorktree,
    shouldFocusWorktree: Bool,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) async {
    let key = normalized(worktree.path)
    guard importingWorktreePaths.insert(key).inserted else { return }
    defer {
      importingWorktreePaths.remove(key)
    }

    if shouldFocusWorktree {
      await focus(worktree, in: claudeViewModel)
      await focus(worktree, in: codexViewModel)
    }

    let requestLimit = pageSize + 1
    let loadedClaudePage = await claudeViewModel.loadLatestSessionsForImport(
      inWorktreePath: key,
      excludingSessionIds: excludedSessionIds(in: key, for: claudeViewModel),
      limit: requestLimit
    )
    let loadedCodexPage = await codexViewModel.loadLatestSessionsForImport(
      inWorktreePath: key,
      excludingSessionIds: excludedSessionIds(in: key, for: codexViewModel),
      limit: requestLimit
    )

    let providerPages = [
      ProviderImportPage(providerKind: .claude, page: loadedClaudePage),
      ProviderImportPage(providerKind: .codex, page: loadedCodexPage),
    ]
    let candidates = providerPages
      .flatMap { providerPage in
        providerPage.page.sessions.map {
          ProviderSessionImportCandidate(providerKind: providerPage.providerKind, session: $0)
        }
      }
      .sorted {
        if $0.session.lastActivityAt == $1.session.lastActivityAt {
          return $0.session.id < $1.session.id
        }
        return $0.session.lastActivityAt > $1.session.lastActivityAt
      }

    let selectedCandidates = Array(candidates.prefix(pageSize))
    let claudeSessions = selectedCandidates.sessions(for: .claude)
    let codexSessions = selectedCandidates.sessions(for: .codex)

    await claudeViewModel.importMonitoredSessions(claudeSessions)
    await codexViewModel.importMonitoredSessions(codexSessions)

    if !claudeSessions.isEmpty {
      await claudeViewModel.refreshImportedWorktreeSessions()
    }
    if !codexSessions.isEmpty {
      await codexViewModel.refreshImportedWorktreeSessions()
    }

    hasMoreByWorktreePath[key] = candidates.count > pageSize || providerPages.contains { $0.page.hasMore }
  }

  private func focus(_ worktree: WorktreeSettingsWorktree, in viewModel: CLISessionsViewModel) async {
    await viewModel.focusExistingWorktree(
      worktree.worktree,
      parentRepositoryPath: worktree.parentModulePath
    )
  }

  private func excludedSessionIds(in worktreePath: String, for viewModel: CLISessionsViewModel) -> Set<String> {
    Set(viewModel.monitoredSessions(inWorktreePath: worktreePath).map(\.id))
  }

  private func normalized(_ path: String) -> String {
    WorktreeModuleResolver.normalizedDirectoryPath(path)
  }
}

private struct ProviderImportPage {
  let providerKind: SessionProviderKind
  let page: WorktreeSessionImportPage
}

private struct ProviderSessionImportCandidate {
  let providerKind: SessionProviderKind
  let session: CLISession
}

private extension Array where Element == ProviderSessionImportCandidate {
  func sessions(for providerKind: SessionProviderKind) -> [CLISession] {
    filter { $0.providerKind == providerKind }.map(\.session)
  }
}
