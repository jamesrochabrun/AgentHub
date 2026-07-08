import Foundation
import Testing

@testable import SimulatorPreview

@Suite("HotReloadMonitor")
@MainActor
struct HotReloadMonitorTests {

  private func makeMonitor() -> HotReloadMonitor {
    let monitor = HotReloadMonitor()
    monitor.settleDelay = 0
    monitor.reloadTimeout = 60 // tests trigger transitions explicitly
    return monitor
  }

  @Test("save → reloading → engine confirms → reloaded, generation bumps")
  func happyPath() {
    let monitor = makeMonitor()
    monitor.arm()
    #expect(monitor.phase == .idle)

    monitor.handle(sourceChanges: [.injectable(path: "/p/HomeView.swift")])
    #expect(monitor.phase == .reloading(fileName: "HomeView.swift"))

    monitor.handle(engineEvent: .injected(summary: "Hot reload complete - Rebound 3 symbols"))
    #expect(monitor.phase == .reloaded(summary: "Hot reload complete - Rebound 3 symbols"))
    #expect(monitor.reloadGeneration == 1)
  }

  @Test("structural change falls back to rebuild")
  func structuralFallsBack() {
    let monitor = makeMonitor()
    monitor.arm()
    var rebuildReasons: [String] = []
    monitor.onRequestRebuild = { rebuildReasons.append($0) }

    monitor.handle(sourceChanges: [
      .structural(path: "/p/NewView.swift", kind: .created)
    ])
    #expect(monitor.phase == .rebuilding(reason: "NewView.swift was created"))
    #expect(rebuildReasons == ["NewView.swift was created"])

    // Saves during the rebuild don't restart the reload cycle.
    monitor.handle(sourceChanges: [.injectable(path: "/p/Other.swift")])
    #expect(monitor.phase == .rebuilding(reason: "NewView.swift was created"))

    monitor.markRebuildFinished(success: true)
    #expect(monitor.phase == .idle)
    #expect(monitor.reloadGeneration == 1)
  }

  @Test("failed injection triggers the automatic rebuild fallback")
  func injectionFailureFallsBack() {
    let monitor = makeMonitor()
    monitor.arm()
    var rebuildReasons: [String] = []
    monitor.onRequestRebuild = { rebuildReasons.append($0) }

    monitor.handle(sourceChanges: [.injectable(path: "/p/HomeView.swift")])
    monitor.handle(engineEvent: .injectionFailed(message: "Compilation failed"))
    #expect(monitor.phase == .rebuilding(reason: "Compilation failed"))
    #expect(rebuildReasons == ["Compilation failed"])
  }

  @Test("failed injection without fallback shows failed")
  func injectionFailureWithoutFallback() {
    let monitor = makeMonitor()
    monitor.automaticRebuildFallback = false
    monitor.arm()

    monitor.handle(engineEvent: .injectionFailed(message: "Compilation failed"))
    #expect(monitor.phase == .failed(message: "Compilation failed"))
  }

  @Test("failed rebuild is reported honestly")
  func rebuildFailure() {
    let monitor = makeMonitor()
    monitor.arm()
    monitor.markRebuildStarted(reason: "NewView.swift was created")
    monitor.markRebuildFinished(success: false, message: "Build failed: error X")
    #expect(monitor.phase == .failed(message: "Build failed: error X"))
    #expect(monitor.reloadGeneration == 0)
  }

  @Test("events are ignored until armed; engineReady arms from preparing")
  func arming() {
    let monitor = makeMonitor()
    monitor.markPreparing(detail: "Building support libraries…")

    monitor.handle(sourceChanges: [.injectable(path: "/p/HomeView.swift")])
    #expect(monitor.phase == .preparing(detail: "Building support libraries…"))

    monitor.handle(engineEvent: .engineReady)
    #expect(monitor.phase == .idle)
  }

  @Test("warnings surface without changing the phase")
  func warnings() {
    let monitor = makeMonitor()
    monitor.arm()
    monitor.handle(engineEvent: .warning(message: "No symbols were replaced"))
    #expect(monitor.phase == .idle)
    #expect(monitor.lastWarning == "No symbols were replaced")
  }

  @Test("stray injection confirmation during a rebuild is ignored")
  func injectedDuringRebuildIgnored() {
    // The non-interposable failure prints warning→complete as a pair: the
    // warning starts the rebuild, and the trailing "✅" must not flip the
    // pill to "Reloaded" or bump the generation — nothing actually rebound.
    let monitor = makeMonitor()
    monitor.arm()
    var rebuilds: [String] = []
    monitor.onRequestRebuild = { rebuilds.append($0) }

    monitor.handle(sourceChanges: [.injectable(path: "/p/HomeView.swift")])
    monitor.handle(engineEvent: .injectionFailed(
      message: "App wasn't built with injection support — rebuilding"))
    #expect(rebuilds.count == 1)
    #expect(monitor.phase == .rebuilding(
      reason: "App wasn't built with injection support — rebuilding"))

    monitor.handle(engineEvent: .injected(summary: "Hot reload complete - Rebound 0 symbols"))
    #expect(monitor.phase == .rebuilding(
      reason: "App wasn't built with injection support — rebuilding"))
    #expect(monitor.reloadGeneration == 0)

    monitor.markRebuildFinished(success: true)
    #expect(monitor.phase == .idle)
    #expect(monitor.reloadGeneration == 1)
  }

  @Test("engine activity extends the reload deadline past the base timeout")
  func engineActivityExtendsDeadline() async throws {
    let monitor = makeMonitor()
    monitor.reloadTimeout = 0.05
    monitor.engineActivityTimeout = 0.5
    monitor.arm()
    var rebuilds: [String] = []
    monitor.onRequestRebuild = { rebuilds.append($0) }

    monitor.handle(sourceChanges: [.injectable(path: "/p/Big.swift")])
    monitor.handle(engineEvent: .recompiling(fileName: "Big.swift"))

    // Well past the base deadline but the engine acknowledged the save —
    // a slow compile must not be mistaken for a dead engine.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(monitor.phase == .reloading(fileName: "Big.swift"))
    #expect(rebuilds.isEmpty)

    // Engine goes silent past the extended deadline — fallback still fires.
    let deadline = Date().addingTimeInterval(2)
    while rebuilds.isEmpty, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(rebuilds == ["Change didn't hot-swap"])
  }

  @Test("engine activity followed by confirmation never rebuilds")
  func engineActivityThenConfirmation() async throws {
    let monitor = makeMonitor()
    monitor.reloadTimeout = 0.05
    monitor.engineActivityTimeout = 0.2
    monitor.arm()
    var rebuilds: [String] = []
    monitor.onRequestRebuild = { rebuilds.append($0) }

    monitor.handle(sourceChanges: [.injectable(path: "/p/HomeView.swift")])
    monitor.handle(engineEvent: .recompiling(fileName: "HomeView.swift"))
    monitor.handle(engineEvent: .injected(summary: "Hot reload complete"))
    #expect(monitor.reloadGeneration == 1)

    try await Task.sleep(nanoseconds: 400_000_000)
    #expect(rebuilds.isEmpty)
  }

  @Test("structural change during a rebuild queues exactly one follow-up")
  func structuralQueuedDuringRebuild() {
    let monitor = makeMonitor()
    monitor.arm()
    var rebuilds: [String] = []
    monitor.onRequestRebuild = { rebuilds.append($0) }

    monitor.handle(sourceChanges: [.structural(path: "/p/New.swift", kind: .created)])
    #expect(rebuilds.count == 1)

    // Mid-rebuild: repeated saves of the same new file coalesce, injectable
    // saves ride along — none of it is dropped.
    for _ in 0..<5 {
      monitor.handle(sourceChanges: [.structural(path: "/p/Another.swift", kind: .created)])
    }
    monitor.handle(sourceChanges: [.injectable(path: "/p/Edited.swift")])
    #expect(rebuilds.count == 1)

    monitor.markRebuildFinished(success: true)
    #expect(rebuilds == [
      "New.swift was created",
      "Another.swift was created during the rebuild",
    ])
    #expect(monitor.phase == .rebuilding(reason: "Another.swift was created during the rebuild"))

    // The follow-up rebuild finishing settles to idle with nothing queued.
    monitor.markRebuildFinished(success: true)
    #expect(monitor.phase == .idle)
    #expect(rebuilds.count == 2)
  }

  @Test("injectable-only saves during a rebuild are covered by it, not replayed")
  func injectableQueueClearsWithoutFollowUp() {
    let monitor = makeMonitor()
    monitor.arm()
    var rebuilds: [String] = []
    monitor.onRequestRebuild = { rebuilds.append($0) }

    monitor.handle(sourceChanges: [.structural(path: "/p/New.swift", kind: .created)])
    monitor.handle(sourceChanges: [.injectable(path: "/p/Edited.swift")])

    monitor.markRebuildFinished(success: true)
    // The rebuild compiled current on-disk sources, so the mid-rebuild save
    // is already in the binary; the generation bump re-renders previews.
    #expect(monitor.phase == .idle)
    #expect(rebuilds.count == 1)
    #expect(monitor.reloadGeneration == 1)
  }

  @Test("a failed rebuild clears the queue without chaining another rebuild")
  func failedRebuildClearsQueue() {
    let monitor = makeMonitor()
    monitor.arm()
    var rebuilds: [String] = []
    monitor.onRequestRebuild = { rebuilds.append($0) }

    monitor.handle(sourceChanges: [.structural(path: "/p/New.swift", kind: .created)])
    monitor.handle(sourceChanges: [.structural(path: "/p/Another.swift", kind: .created)])

    monitor.markRebuildFinished(success: false, message: "Build failed")
    #expect(monitor.phase == .failed(message: "Build failed"))
    #expect(rebuilds.count == 1)

    // Re-arming starts clean — the stale queue must not resurface.
    monitor.arm()
    monitor.markRebuildStarted(reason: "manual")
    monitor.markRebuildFinished(success: true)
    #expect(monitor.phase == .idle)
    #expect(rebuilds.count == 1)
  }

  @Test("reload timeout falls back to rebuild")
  func reloadTimeout() async throws {
    let monitor = makeMonitor()
    monitor.reloadTimeout = 0.02
    monitor.arm()
    await confirmation { confirmed in
      monitor.onRequestRebuild = { _ in confirmed() }
      monitor.handle(sourceChanges: [.injectable(path: "/p/HomeView.swift")])
      // Let the timeout task fire.
      let deadline = Date().addingTimeInterval(1)
      while monitor.phase == .reloading(fileName: "HomeView.swift"),
            Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }
    #expect(monitor.phase == .rebuilding(reason: "Change didn't hot-swap"))
  }
}
