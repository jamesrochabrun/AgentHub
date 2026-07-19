//
//  EphemeralDefaultsSuite.swift
//  AgentHubTests
//
//  Ephemeral UserDefaults suite for tests.
//

import Foundation

/// Ephemeral UserDefaults suite for tests. Call `cleanUp()` (in a `defer`) so
/// the suite leaves nothing behind under ~/Library/Preferences — neither its
/// keys nor the empty plist cfprefsd materializes for a touched domain.
struct EphemeralDefaultsSuite {
  let defaults: UserDefaults
  let suiteName: String
  private let prefix: String

  init(prefix: String = "com.agenthub.tests.suite") {
    self.prefix = prefix
    // The UUID guarantees a fresh domain, so nothing pre-existing needs to
    // be cleared here — and not touching the domain up front keeps cfprefsd
    // from materializing a plist for suites that only ever read.
    suiteName = "\(prefix).\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
    EphemeralDefaultsSuite.sweepResidue(prefix: prefix, ownSuiteName: suiteName)
  }

  /// cfprefsd flushes an empty plist for every touched domain when the test
  /// process exits — after any in-test code has run — so a suite usually
  /// cannot delete its own file. Instead each cleanUp removes what it can and
  /// sweeps residue that earlier test runs left for the same prefix; the age
  /// gate keeps files belonging to concurrently running suites safe.
  private static func sweepResidue(prefix: String, ownSuiteName: String) {
    let fileManager = FileManager.default
    let preferences = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences", isDirectory: true)
    try? fileManager.removeItem(at: preferences.appendingPathComponent("\(ownSuiteName).plist"))
    let staleCutoff = Date(timeIntervalSinceNow: -600)
    let files = (try? fileManager.contentsOfDirectory(
      at: preferences,
      includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    for file in files where file.lastPathComponent.hasPrefix("\(prefix).") {
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantFuture
      if modified < staleCutoff {
        try? fileManager.removeItem(at: file)
      }
    }
  }
}
