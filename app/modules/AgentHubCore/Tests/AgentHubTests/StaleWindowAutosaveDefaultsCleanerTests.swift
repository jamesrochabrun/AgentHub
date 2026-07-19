//
//  StaleWindowAutosaveDefaultsCleanerTests.swift
//  AgentHubTests
//

import Foundation
import Testing
@testable import AgentHubCore

@Suite("StaleWindowAutosaveDefaultsCleaner")
struct StaleWindowAutosaveDefaultsCleanerTests {

  private static let staleWindowFrameKey =
    "NSWindow Frame SwiftUI.ModifiedContent<AgentHubCore.AgentHubSessionsView, "
    + "AgentHubCore.(unknown context at $10154d75c).AgentHubModifier>-1-AppWindow-1"

  private static let staleSplitViewKey =
    "NSSplitView Subview Frames SwiftUI.ModifiedContent<AgentHubCore.AgentHubSessionsView, "
    + "AgentHubCore.(unknown context at $100b5575c).AgentHubModifier>-1-AppWindow-1, SidebarNavigationSplitView"

  private static let stableWindowFrameKey =
    "NSWindow Frame SwiftUI.ModifiedContent<AgentHubCore.AgentHubSessionsView, "
    + "AgentHubCore.AgentHubModifier>-1-AppWindow-1"

  @Test("removes per-launch autosave keys and reports the count")
  func removesStaleAutosaveKeys() {
    let suite = EphemeralDefaultsSuite(prefix: "com.agenthub.tests.autosave-cleaner")
    defer { suite.cleanUp() }
    suite.defaults.set("10 10 100 100", forKey: Self.staleWindowFrameKey)
    suite.defaults.set(["260.0", "1180.0"], forKey: Self.staleSplitViewKey)

    let removed = StaleWindowAutosaveDefaultsCleaner(defaults: suite.defaults, domainName: suite.suiteName).purgeStaleAutosaveKeys()

    #expect(removed == 2)
    #expect(suite.defaults.object(forKey: Self.staleWindowFrameKey) == nil)
    #expect(suite.defaults.object(forKey: Self.staleSplitViewKey) == nil)
  }

  @Test("preserves stable autosave keys and unrelated keys")
  func preservesLiveKeys() {
    let suite = EphemeralDefaultsSuite(prefix: "com.agenthub.tests.autosave-cleaner")
    defer { suite.cleanUp() }
    suite.defaults.set("10 10 100 100", forKey: Self.stableWindowFrameKey)
    suite.defaults.set(true, forKey: "com.agenthub.hub.someSetting")
    // Unrelated key that merely mentions a private context must survive:
    // only window/split-view autosave entries are ever dead by construction.
    suite.defaults.set("x", forKey: "com.agenthub.debug.(unknown context at $1234).note")

    let removed = StaleWindowAutosaveDefaultsCleaner(defaults: suite.defaults, domainName: suite.suiteName).purgeStaleAutosaveKeys()

    #expect(removed == 0)
    #expect(suite.defaults.string(forKey: Self.stableWindowFrameKey) == "10 10 100 100")
    #expect(suite.defaults.bool(forKey: "com.agenthub.hub.someSetting"))
    #expect(suite.defaults.string(forKey: "com.agenthub.debug.(unknown context at $1234).note") == "x")
  }

  @Test("falls back to per-key removal when no domain name is available")
  func fallbackPathRemovesStaleKeys() {
    let suite = EphemeralDefaultsSuite(prefix: "com.agenthub.tests.autosave-cleaner")
    defer { suite.cleanUp() }
    suite.defaults.set("10 10 100 100", forKey: Self.staleWindowFrameKey)
    suite.defaults.set(true, forKey: "com.agenthub.hub.someSetting")

    let removed = StaleWindowAutosaveDefaultsCleaner(defaults: suite.defaults, domainName: nil).purgeStaleAutosaveKeys()

    #expect(removed == 1)
    #expect(suite.defaults.object(forKey: Self.staleWindowFrameKey) == nil)
    #expect(suite.defaults.bool(forKey: "com.agenthub.hub.someSetting"))
  }

  @Test("second purge is a no-op")
  func secondPurgeRemovesNothing() {
    let suite = EphemeralDefaultsSuite(prefix: "com.agenthub.tests.autosave-cleaner")
    defer { suite.cleanUp() }
    suite.defaults.set("10 10 100 100", forKey: Self.staleWindowFrameKey)

    let cleaner = StaleWindowAutosaveDefaultsCleaner(defaults: suite.defaults, domainName: suite.suiteName)
    #expect(cleaner.purgeStaleAutosaveKeys() == 1)
    #expect(cleaner.purgeStaleAutosaveKeys() == 0)
  }
}
