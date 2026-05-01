import Testing

@testable import AgentHubCore

@Suite("Repository restore persistence gate")
struct RepositoryRestorePersistenceGateTests {
  @Test("Skips initial empty emission while launch restore is pending")
  func skipsInitialEmptyEmissionWhileRestoreIsPending() {
    let shouldPersist = CLISessionsViewModel.shouldPersistRepositoryEmission(
      repositoryCount: 0,
      persistedRepositoryPathCountOnLaunch: 2,
      hasObservedNonEmptyRepositoryEmissionSinceLaunch: false
    )

    #expect(!shouldPersist)
  }

  @Test("Skips empty emissions until restored repositories are observed")
  func skipsEmptyEmissionsUntilRestoredRepositoriesAreObserved() {
    let shouldPersist = CLISessionsViewModel.shouldPersistRepositoryEmission(
      repositoryCount: 0,
      persistedRepositoryPathCountOnLaunch: 2,
      hasObservedNonEmptyRepositoryEmissionSinceLaunch: false
    )

    #expect(!shouldPersist)
  }

  @Test("Persists empty emission after repositories have been observed")
  func persistsEmptyEmissionAfterRepositoriesHaveBeenObserved() {
    let shouldPersist = CLISessionsViewModel.shouldPersistRepositoryEmission(
      repositoryCount: 0,
      persistedRepositoryPathCountOnLaunch: 2,
      hasObservedNonEmptyRepositoryEmissionSinceLaunch: true
    )

    #expect(shouldPersist)
  }

  @Test("Persists populated emissions during launch restore")
  func persistsPopulatedEmissionDuringRestore() {
    let shouldPersist = CLISessionsViewModel.shouldPersistRepositoryEmission(
      repositoryCount: 1,
      persistedRepositoryPathCountOnLaunch: 2,
      hasObservedNonEmptyRepositoryEmissionSinceLaunch: false
    )

    #expect(shouldPersist)
  }

  @Test("Persists empty emission when there was no persisted launch state")
  func persistsEmptyEmissionWithoutPersistedLaunchState() {
    let shouldPersist = CLISessionsViewModel.shouldPersistRepositoryEmission(
      repositoryCount: 0,
      persistedRepositoryPathCountOnLaunch: 0,
      hasObservedNonEmptyRepositoryEmissionSinceLaunch: false
    )

    #expect(shouldPersist)
  }
}
