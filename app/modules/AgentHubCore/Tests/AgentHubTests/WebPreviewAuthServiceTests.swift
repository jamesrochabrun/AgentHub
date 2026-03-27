import Foundation
import Testing
import WebKit

@testable import AgentHubCore

@MainActor
@Suite("WebPreviewAuthService")
struct WebPreviewAuthServiceTests {

  // MARK: - Data Store Isolation

  @Test("Returns same data store for same project path")
  func returnsSameDataStoreForSameProject() {
    // Enable persistent auth for this test
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled)
    defer { UserDefaults.standard.removeObject(forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled) }

    let service = WebPreviewAuthService.shared
    let path = "/test/project/\(UUID().uuidString)"

    let store1 = service.dataStore(for: path)
    let store2 = service.dataStore(for: path)

    #expect(store1 === store2)
  }

  @Test("Returns different data stores for different projects")
  func returnsDifferentDataStoresForDifferentProjects() {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled)
    defer { UserDefaults.standard.removeObject(forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled) }

    let service = WebPreviewAuthService.shared
    let pathA = "/test/project-a/\(UUID().uuidString)"
    let pathB = "/test/project-b/\(UUID().uuidString)"

    let storeA = service.dataStore(for: pathA)
    let storeB = service.dataStore(for: pathB)

    #expect(storeA !== storeB)
  }

  // MARK: - Process Pool Sharing

  @Test("Returns same process pool for same project")
  func returnsSameProcessPoolForSameProject() {
    let service = WebPreviewAuthService.shared
    let path = "/test/project/\(UUID().uuidString)"

    let pool1 = service.processPool(for: path)
    let pool2 = service.processPool(for: path)

    #expect(pool1 === pool2)
  }

  @Test("Returns different process pools for different projects")
  func returnsDifferentProcessPoolsForDifferentProjects() {
    let service = WebPreviewAuthService.shared
    let pathA = "/test/project-a/\(UUID().uuidString)"
    let pathB = "/test/project-b/\(UUID().uuidString)"

    let poolA = service.processPool(for: pathA)
    let poolB = service.processPool(for: pathB)

    #expect(poolA !== poolB)
  }

  // MARK: - Default Off Behavior

  @Test("Returns non-persistent store when feature is disabled")
  func returnsNonPersistentStoreWhenDisabled() {
    UserDefaults.standard.set(false, forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled)
    defer { UserDefaults.standard.removeObject(forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled) }

    let service = WebPreviewAuthService.shared
    let path = "/test/project/\(UUID().uuidString)"

    let store = service.dataStore(for: path)

    // Non-persistent store should not be the default store
    #expect(!store.isPersistent)
  }

  @Test("hasPersistedAuth returns false when feature is disabled")
  func hasPersistedAuthReturnsFalseWhenDisabled() {
    UserDefaults.standard.set(false, forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled)
    defer { UserDefaults.standard.removeObject(forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled) }

    let service = WebPreviewAuthService.shared
    #expect(!service.hasPersistedAuth(for: "/any/path"))
  }

  // MARK: - Clear Session

  @Test("Clear session removes data store for project")
  func clearSessionRemovesDataStore() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled)
    defer { UserDefaults.standard.removeObject(forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled) }

    let service = WebPreviewAuthService.shared
    let path = "/test/project/\(UUID().uuidString)"

    // Create a store
    _ = service.dataStore(for: path)
    #expect(service.hasPersistedAuth(for: path))

    // Clear it
    await service.clearSession(for: path)
    #expect(!service.hasPersistedAuth(for: path))
  }
}
