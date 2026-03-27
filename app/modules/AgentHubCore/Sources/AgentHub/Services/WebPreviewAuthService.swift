//
//  WebPreviewAuthService.swift
//  AgentHub
//
//  Manages persistent cookie storage for web preview authentication.
//  Each project gets its own isolated WKWebsiteDataStore so login sessions
//  don't leak across projects. Opt-in via webPreviewPersistentAuthEnabled.
//

import Foundation
import WebKit

// MARK: - Protocol

/// Provides per-project isolated web data stores for persistent authentication.
///
/// Security model:
/// - Each project gets its own `WKWebsiteDataStore(forIdentifier:)` — cookies,
///   localStorage, IndexedDB, and cache are fully siloed at the WebKit level.
/// - Cookie scoping follows standard browser rules (same-origin only).
/// - All data is local (`~/Library/WebKit/`), never synced or transmitted.
/// - Feature is opt-in (default off). When disabled, returns a non-persistent store.
protocol WebPreviewAuthServiceProtocol: Sendable {
  @MainActor func dataStore(for projectPath: String) -> WKWebsiteDataStore
  @MainActor func processPool(for projectPath: String) -> WKProcessPool
  @MainActor func clearSession(for projectPath: String) async
  @MainActor func clearAllSessions() async
  @MainActor func hasPersistedAuth(for projectPath: String) -> Bool
}

// MARK: - Implementation

@MainActor
@Observable
final class WebPreviewAuthService: WebPreviewAuthServiceProtocol {

  static let shared = WebPreviewAuthService()

  private var dataStores: [String: WKWebsiteDataStore] = [:]
  private var processPools: [String: WKProcessPool] = [:]
  private var nonPersistentStore: WKWebsiteDataStore?

  private init() {}

  /// Whether persistent auth is enabled (opt-in setting).
  private var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: AgentHubDefaults.webPreviewPersistentAuthEnabled)
  }

  /// Returns the data store for the given project path.
  /// When persistent auth is disabled, returns a non-persistent (ephemeral) store.
  func dataStore(for projectPath: String) -> WKWebsiteDataStore {
    guard isEnabled else {
      if nonPersistentStore == nil {
        nonPersistentStore = WKWebsiteDataStore.nonPersistent()
      }
      return nonPersistentStore!
    }

    if let existing = dataStores[projectPath] {
      return existing
    }

    let id = resolveOrCreateIdentifier(for: projectPath)
    let store = WKWebsiteDataStore(forIdentifier: id)
    dataStores[projectPath] = store
    return store
  }

  /// Returns a shared process pool for the given project, enabling cookie sharing
  /// across multiple WKWebViews within the same project.
  func processPool(for projectPath: String) -> WKProcessPool {
    if let existing = processPools[projectPath] {
      return existing
    }
    let pool = WKProcessPool()
    processPools[projectPath] = pool
    return pool
  }

  /// Removes all website data (cookies, localStorage, cache, etc.) for a specific project.
  func clearSession(for projectPath: String) async {
    guard let store = dataStores[projectPath] else { return }
    let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
    let records = await store.dataRecords(ofTypes: allTypes)
    await store.removeData(ofTypes: allTypes, for: records)
    dataStores.removeValue(forKey: projectPath)
    processPools.removeValue(forKey: projectPath)
  }

  /// Removes all website data for every project and clears all stored identifiers.
  func clearAllSessions() async {
    for projectPath in Array(dataStores.keys) {
      await clearSession(for: projectPath)
    }
    // Clear any identifiers for projects not currently loaded
    UserDefaults.standard.removeObject(forKey: AgentHubDefaults.webPreviewDataStoreIdentifiers)
  }

  /// Whether there is a persistent data store created for this project.
  func hasPersistedAuth(for projectPath: String) -> Bool {
    isEnabled && dataStores[projectPath] != nil
  }

  // MARK: - Identifier Management

  private func resolveOrCreateIdentifier(for projectPath: String) -> UUID {
    var mapping = loadIdentifierMapping()
    if let existing = mapping[projectPath], let uuid = UUID(uuidString: existing) {
      return uuid
    }
    let newID = UUID()
    mapping[projectPath] = newID.uuidString
    saveIdentifierMapping(mapping)
    return newID
  }

  private func loadIdentifierMapping() -> [String: String] {
    guard let data = UserDefaults.standard.data(forKey: AgentHubDefaults.webPreviewDataStoreIdentifiers),
          let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
      return [:]
    }
    return mapping
  }

  private func saveIdentifierMapping(_ mapping: [String: String]) {
    if let data = try? JSONEncoder().encode(mapping) {
      UserDefaults.standard.set(data, forKey: AgentHubDefaults.webPreviewDataStoreIdentifiers)
    }
  }
}
