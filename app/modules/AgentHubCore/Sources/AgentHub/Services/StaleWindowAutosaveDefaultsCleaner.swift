//
//  StaleWindowAutosaveDefaultsCleaner.swift
//  AgentHub
//
//  Purges dead window/split-view autosave keys from UserDefaults.
//

import Foundation

// MARK: - StaleWindowAutosaveDefaultsCleanerProtocol

/// Removes window/split-view autosave defaults keys that older builds minted
/// with per-launch-unique names.
///
/// SwiftUI derives the `NSWindow Frame …` and `NSSplitView Subview Frames …`
/// autosave keys from the window's root view type name. While
/// `AgentHubModifier` was `private`, its runtime type name embedded an
/// ASLR-dependent `(unknown context at $…)` discriminator, so every launch
/// wrote a fresh key that no later launch could ever read. Thousands of dead
/// keys make CFPrefs dictionary merges and KVO delivery O(domain size), which
/// hangs the main thread whenever AppKit persists the window frame.
public protocol StaleWindowAutosaveDefaultsCleanerProtocol: Sendable {
  /// Deletes stale autosave keys and returns how many were removed.
  @discardableResult
  func purgeStaleAutosaveKeys() -> Int
}

// MARK: - StaleWindowAutosaveDefaultsCleaner

public struct StaleWindowAutosaveDefaultsCleaner: StaleWindowAutosaveDefaultsCleanerProtocol {

  private let defaults: UserDefaults
  private let domainName: String?

  public init(defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier) {
    self.defaults = defaults
    self.domainName = domainName
  }

  @discardableResult
  public func purgeStaleAutosaveKeys() -> Int {
    // Per-key removeObject(forKey:) is one cfprefsd round trip per key against
    // a domain whose per-operation cost grows with its size — O(N²) across a
    // multi-thousand-key backlog. CFPreferencesSetMultiple removes the whole
    // batch in a single call without replacing the domain, so concurrent
    // writes to other keys are never clobbered.
    if let domainName, let domain = defaults.persistentDomain(forName: domainName) {
      let staleKeys = domain.keys.filter(Self.isStaleAutosaveKey)
      guard !staleKeys.isEmpty else { return 0 }
      CFPreferencesSetMultiple(
        nil,
        staleKeys as CFArray,
        domainName as CFString,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
      )
      CFPreferencesAppSynchronize(domainName as CFString)
      return staleKeys.count
    }
    let staleKeys = defaults.dictionaryRepresentation().keys.filter(Self.isStaleAutosaveKey)
    for key in staleKeys {
      defaults.removeObject(forKey: key)
    }
    return staleKeys.count
  }

  /// A key is stale only when it is a window/split-view autosave entry whose
  /// embedded view type name contains a private-context discriminator — such
  /// keys are unreadable on any later launch by construction, so removing
  /// them can never lose state a future launch could use.
  static func isStaleAutosaveKey(_ key: String) -> Bool {
    (key.hasPrefix("NSWindow Frame ") || key.hasPrefix("NSSplitView Subview Frames "))
      && key.contains("(unknown context at $")
  }
}
