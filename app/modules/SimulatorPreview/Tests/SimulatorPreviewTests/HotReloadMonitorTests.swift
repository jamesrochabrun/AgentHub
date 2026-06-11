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
