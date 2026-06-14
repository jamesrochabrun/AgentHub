//
//  SimulatorHotReloadControllerTests.swift
//  AgentHub
//
//  Tests the panel-side glue: plan preparation against the artifact cache,
//  launch arming (watcher + console tail wiring), and the structural-change →
//  rebuild fallback path, all with injected mocks.
//

import Foundation
import Testing
@testable import AgentHubCore
import SimulatorPreview

// MARK: - Mocks

private final class MockArtifactStore: HotReloadArtifactProviding, @unchecked Sendable {
  var cached: HotReloadArtifacts?
  var prepared: HotReloadArtifacts
  var prepareCallCount = 0

  init(cached: HotReloadArtifacts?, prepared: HotReloadArtifacts? = nil) {
    self.cached = cached
    self.prepared = prepared ?? cached ?? HotReloadArtifacts(
      injectionDylibPath: nil, previewHostDylibPath: nil, frameworkSearchPaths: [])
  }

  func cachedArtifacts() async -> HotReloadArtifacts? { cached }

  func prepareArtifacts(
    progress: (@Sendable (String) -> Void)?
  ) async throws -> HotReloadArtifacts {
    prepareCallCount += 1
    cached = prepared
    return prepared
  }
}

private final class MockSourceWatcher: HotReloadSourceWatching {
  var startedProjectPath: String?
  var onChange: (([HotReloadSourceChange]) -> Void)?
  var stopCount = 0

  func start(
    projectPath: String,
    onChange: @escaping ([HotReloadSourceChange]) -> Void
  ) {
    startedProjectPath = projectPath
    self.onChange = onChange
  }

  func stop() {
    stopCount += 1
    onChange = nil
  }
}

private final class MockConsoleTail: HotReloadConsoleTailing {
  var startedPath: String?
  var onLine: ((String) -> Void)?
  var stopCount = 0

  func start(path: String, onLine: @escaping (String) -> Void) {
    startedPath = path
    self.onLine = onLine
  }

  func stop() {
    stopCount += 1
    onLine = nil
  }
}

private struct MockPreviewClient: PreviewHostClientProtocol {
  func listPreviews() async throws -> [PreviewHostPreviewType] { [] }
  func render(typeName: String, previewId: String) async throws -> PreviewHostRenderResult {
    PreviewHostRenderResult(displayName: nil, imageData: nil, errorMessage: nil)
  }
}

// MARK: - Tests

@Suite("SimulatorHotReloadController")
@MainActor
struct SimulatorHotReloadControllerTests {

  private static let artifacts = HotReloadArtifacts(
    injectionDylibPath: "/cache/AgentHubInjection.framework/AgentHubInjection",
    previewHostDylibPath: "/cache/AgentHubPreviewHost.framework/AgentHubPreviewHost",
    frameworkSearchPaths: ["/cache"]
  )

  private func makeController(
    cached: HotReloadArtifacts?,
    rebuildResult: Bool = true,
    rebuilds: RebuildLog = RebuildLog(),
    seededFiles: [String] = []
  ) -> (SimulatorHotReloadController, MockSourceWatcher, MockConsoleTail) {
    let watcher = MockSourceWatcher()
    let tail = MockConsoleTail()
    let controller = SimulatorHotReloadController(
      artifactStore: MockArtifactStore(cached: cached),
      sourceWatcher: watcher,
      consoleTail: tail,
      previewClient: MockPreviewClient(),
      seedChangedFiles: { _ in seededFiles },
      rebuildExecutor: { udid, projectPath, _ in
        rebuilds.append("\(udid)|\(projectPath)")
        return rebuildResult
      }
    )
    return (controller, watcher, tail)
  }

  final class RebuildLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var entries: [String] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    func append(_ entry: String) {
      lock.lock()
      storage.append(entry)
      lock.unlock()
    }
  }

  @Test("disabled features yield no plan and a disabled pill")
  func disabled() async {
    let (controller, _, _) = makeController(cached: Self.artifacts)
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: false, enablePreviews: false)
    #expect(plan == nil)
    #expect(controller.monitor.phase == .disabled)
  }

  @Test("cached artifacts produce an effective plan with a console log")
  func planFromCache() async {
    let (controller, _, _) = makeController(cached: Self.artifacts)
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: true, enablePreviews: true)

    #expect(plan != nil)
    #expect(plan?.configuration.isEffective == true)
    #expect(plan?.consoleStdoutPath?.hasSuffix(".log") == true)
  }

  @Test("missing artifacts: launch proceeds plain, support builds in background")
  func missingArtifacts() async {
    let (controller, _, _) = makeController(cached: nil)
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: true, enablePreviews: true)

    #expect(plan == nil)
    // Either still preparing or already reported ready-on-next-run.
    switch controller.monitor.phase {
    case .preparing, .unavailable: break
    default: Issue.record("unexpected phase \(controller.monitor.phase)")
    }
  }

  @Test("launch arms the monitor and starts the console tail")
  func launchArms() async {
    let (controller, watcher, tail) = makeController(cached: Self.artifacts)
    controller.startTracking(projectPath: "/p")
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: true, enablePreviews: true)!

    controller.sessionDidLaunch(udid: "UDID", projectPath: "/p", plan: plan)

    #expect(controller.monitor.phase == .idle)
    #expect(controller.previewHostGeneration == 1)
    #expect(watcher.startedProjectPath == "/p")
    #expect(tail.startedPath == plan.consoleStdoutPath)

    // Console lines flow through the parser into the monitor, and recompile
    // events count as changed files for the spotlight.
    tail.onLine?("🔥 🔄 [HomeView.swift] Recompiling")
    #expect(controller.monitor.phase == .reloading(fileName: "HomeView.swift"))
    #expect(controller.changedSourceFiles.first == "HomeView.swift")
    tail.onLine?("🔥 ✅ Hot reload complete - Rebound 2 symbols")
    #expect(controller.monitor.reloadGeneration == 1)
  }

  @Test("previews-only launch keeps the pill off but stores the plan")
  func previewsOnlyLaunch() async {
    let (controller, _, _) = makeController(cached: Self.artifacts)
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: false, enablePreviews: true)!

    controller.sessionDidLaunch(udid: "UDID", projectPath: "/p", plan: plan)

    #expect(controller.monitor.phase == .disabled)
    #expect(controller.activePlan == plan)
    #expect(controller.previewHostGeneration == 1)
  }

  @Test("tracking runs independently of arming and seeds from git")
  func trackingIndependentOfArming() async {
    let (controller, watcher, _) = makeController(
      cached: Self.artifacts, seededFiles: ["Seeded.swift", "Other.swift"])

    controller.startTracking(projectPath: "/p")
    #expect(watcher.startedProjectPath == "/p")

    // Changes count before any launch is armed (the pill stays disabled).
    watcher.onChange?([.injectable(path: "/p/Live.swift")])
    #expect(controller.monitor.phase == .disabled)
    #expect(controller.changedSourceFiles.first == "Live.swift")

    // Git seeds land behind live edits, deduplicated.
    let deadline = Date().addingTimeInterval(2)
    while controller.changedSourceFiles.count < 3, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(controller.changedSourceFiles == ["Live.swift", "Seeded.swift", "Other.swift"])

    // Stopping an armed session keeps tracking (panel still open).
    controller.sessionDidStop()
    watcher.onChange?([.injectable(path: "/p/After.swift")])
    #expect(controller.changedSourceFiles.first == "After.swift")
  }

  @Test("preview observation toggles source tracking and candidate updates")
  func previewObservationToggle() async {
    let (controller, watcher, _) = makeController(
      cached: Self.artifacts, seededFiles: ["Seeded.swift"])

    controller.setPreviewObservationEnabled(false, projectPath: "/p")
    #expect(watcher.startedProjectPath == nil)
    #expect(controller.changedSourceFiles.isEmpty)

    controller.setPreviewObservationEnabled(true, projectPath: "/p")
    #expect(watcher.startedProjectPath == "/p")

    watcher.onChange?([.injectable(path: "/p/Live.swift")])
    #expect(controller.changedSourceFiles.first == "Live.swift")

    let deadline = Date().addingTimeInterval(2)
    while controller.changedSourceFiles.count < 2, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(controller.changedSourceFiles == ["Live.swift", "Seeded.swift"])

    controller.setPreviewObservationEnabled(false, projectPath: "/p")
    #expect(watcher.stopCount == 1)
    #expect(controller.changedSourceFiles.isEmpty)
  }

  @Test("injection observation does not populate preview candidates when previews are disabled")
  func injectionObservationWithoutPreviewCandidates() async {
    let (controller, watcher, tail) = makeController(cached: Self.artifacts)
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: true, enablePreviews: false)!

    controller.sessionDidLaunch(udid: "UDID", projectPath: "/p", plan: plan)
    #expect(watcher.startedProjectPath == "/p")

    watcher.onChange?([.injectable(path: "/p/Live.swift")])
    #expect(controller.changedSourceFiles.isEmpty)
    #expect(controller.monitor.phase == .reloading(fileName: "Live.swift"))

    tail.onLine?("🔥 🔄 [Console.swift] Recompiling")
    #expect(controller.changedSourceFiles.isEmpty)
    #expect(controller.monitor.phase == .reloading(fileName: "Console.swift"))
  }

  @Test("structural change triggers the rebuild executor and settles to idle")
  func structuralRebuild() async {
    let rebuilds = RebuildLog()
    let (controller, watcher, _) = makeController(
      cached: Self.artifacts, rebuildResult: true, rebuilds: rebuilds)
    controller.startTracking(projectPath: "/p")
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: true, enablePreviews: false)!
    controller.sessionDidLaunch(udid: "UDID", projectPath: "/p", plan: plan)

    watcher.onChange?([.structural(path: "/p/New.swift", kind: .created)])

    // The rebuild runs in a Task; wait for it to finish.
    let deadline = Date().addingTimeInterval(2)
    while rebuilds.entries.isEmpty || controller.monitor.phase != .idle,
          Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(rebuilds.entries == ["UDID|/p"])
    #expect(controller.monitor.phase == .idle)
    #expect(controller.monitor.reloadGeneration == 1)
  }

  @Test("stop tears down the console + pill; stopTracking stops the watcher")
  func stop() async {
    let (controller, watcher, tail) = makeController(cached: Self.artifacts)
    controller.startTracking(projectPath: "/p")
    let plan = await controller.preparePlan(
      udid: "UDID", projectPath: "/p", enableInjection: true, enablePreviews: true)!
    controller.sessionDidLaunch(udid: "UDID", projectPath: "/p", plan: plan)

    controller.sessionDidStop()
    #expect(controller.monitor.phase == .disabled)
    #expect(controller.activePlan == nil)
    #expect(tail.stopCount >= 1)
    #expect(watcher.stopCount == 0) // panel still open — tracking continues

    controller.stopTracking()
    #expect(watcher.stopCount == 1)
  }
}
