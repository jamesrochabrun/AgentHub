import Combine
import Foundation
import Testing

@testable import AgentHubCore

private struct WebPreviewCandidateFixture {
  let root: URL

  static func create() throws -> WebPreviewCandidateFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebPreviewCandidateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return WebPreviewCandidateFixture(root: root)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ relativePath: String, content: String) throws {
    let fileURL = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var currentDate: Date

  init(currentDate: Date) {
    self.currentDate = currentDate
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return currentDate
  }

  func advance(by timeInterval: TimeInterval) {
    lock.lock()
    currentDate = currentDate.addingTimeInterval(timeInterval)
    lock.unlock()
  }
}

private actor WebPreviewCandidateEvaluatorSpy {
  private var queuedStatuses: [WebPreviewCandidateStatus]
  private(set) var evaluationCount = 0
  private let delay: Duration?

  init(
    queuedStatuses: [WebPreviewCandidateStatus],
    delay: Duration? = nil
  ) {
    self.queuedStatuses = queuedStatuses
    self.delay = delay
  }

  func evaluate(projectPath _: String) async -> WebPreviewCandidateStatus {
    evaluationCount += 1
    if let delay {
      try? await Task.sleep(for: delay)
    }

    guard !queuedStatuses.isEmpty else {
      return .notCandidate
    }

    return queuedStatuses.removeFirst()
  }
}

private actor StubMonitorService: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private actor StubFileWatcher: SessionFileWatcherProtocol {
  private nonisolated let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()

  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

private actor MockWebPreviewCandidateService: WebPreviewCandidateServiceProtocol {
  private let status: WebPreviewCandidateStatus
  private let cachedStatus: WebPreviewCandidateStatus?
  private(set) var invalidatedProjectPaths: [String] = []

  init(
    status: WebPreviewCandidateStatus = .notCandidate,
    cachedStatus: WebPreviewCandidateStatus? = nil
  ) {
    self.status = status
    self.cachedStatus = cachedStatus
  }

  func cachedCandidateStatus(for projectPath: String) async -> WebPreviewCandidateStatus? {
    cachedStatus
  }

  func candidateStatus(for projectPath: String) async -> WebPreviewCandidateStatus {
    status
  }

  func invalidate(projectPath: String) async {
    invalidatedProjectPaths.append(projectPath)
  }

  func recordedInvalidations() -> [String] {
    invalidatedProjectPaths
  }
}

@Suite("WebPreviewCandidateService")
struct WebPreviewCandidateServiceTests {

  @Test("Known framework package is a candidate without monitor state")
  func knownFrameworkPackageIsCandidate() async throws {
    let fixture = try WebPreviewCandidateFixture.create()
    defer { fixture.cleanup() }

    try fixture.write(
      "package.json",
      content: #"{"dependencies":{"next":"15.0.0"}}"#
    )

    let status = await WebPreviewCandidateService().candidateStatus(for: fixture.root.path)

    #expect(status == .candidate(reason: .knownFramework))
  }

  @Test("Static index entry is a candidate")
  func staticIndexEntryIsCandidate() async throws {
    let fixture = try WebPreviewCandidateFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("public/index.html", content: "<html></html>")

    let status = await WebPreviewCandidateService().candidateStatus(for: fixture.root.path)

    #expect(status == .candidate(reason: .staticEntry))
  }

  @Test("One-level-deep static app is a candidate from the repo root")
  func oneLevelDeepStaticAppIsCandidate() async throws {
    let fixture = try WebPreviewCandidateFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("easel-landing-page/index.html", content: "<html></html>")

    let status = await WebPreviewCandidateService().candidateStatus(for: fixture.root.path)

    #expect(status == .candidate(reason: .staticEntry))
  }

  @Test("Package preview script is treated as a likely web package")
  func packagePreviewScriptIsLikelyWebPackage() async throws {
    let fixture = try WebPreviewCandidateFixture.create()
    defer { fixture.cleanup() }

    try fixture.write(
      "package.json",
      content: #"{"scripts":{"preview":"custom-preview-command"}}"#
    )

    let status = await WebPreviewCandidateService().candidateStatus(for: fixture.root.path)

    #expect(status == .candidate(reason: .likelyWebPackage))
  }

  @Test("Non-web repo is not a candidate")
  func nonWebRepoIsNotCandidate() async throws {
    let fixture = try WebPreviewCandidateFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("README.md", content: "# AgentHub")

    let status = await WebPreviewCandidateService().candidateStatus(for: fixture.root.path)

    #expect(status == .notCandidate)
  }

  @Test("Two-level-deep static app is not considered by the shallow classifier")
  func twoLevelDeepStaticAppIsNotConsidered() async throws {
    let fixture = try WebPreviewCandidateFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("apps/easel-landing-page/index.html", content: "<html></html>")

    let status = await WebPreviewCandidateService().candidateStatus(for: fixture.root.path)

    #expect(status == .notCandidate)
  }

  @Test("Concurrent requests share one in-flight computation")
  func concurrentRequestsShareOneInFlightComputation() async {
    let spy = WebPreviewCandidateEvaluatorSpy(
      queuedStatuses: [.candidate(reason: .likelyWebPackage)],
      delay: .milliseconds(50)
    )
    let service = WebPreviewCandidateService(
      evaluator: { projectPath in
        await spy.evaluate(projectPath: projectPath)
      }
    )

    async let first = service.candidateStatus(for: "/tmp/project")
    async let second = service.candidateStatus(for: "/tmp/project")

    let firstResult = await first
    let secondResult = await second
    let evaluationCount = await spy.evaluationCount

    #expect(firstResult == .candidate(reason: .likelyWebPackage))
    #expect(secondResult == .candidate(reason: .likelyWebPackage))
    #expect(evaluationCount == 1)
  }

  @Test("Negative cache expires and re-evaluates")
  func negativeCacheExpiresAndReevaluates() async {
    let clock = TestClock(currentDate: Date(timeIntervalSince1970: 0))
    let spy = WebPreviewCandidateEvaluatorSpy(
      queuedStatuses: [
        .notCandidate,
        .candidate(reason: .staticEntry),
      ]
    )
    let service = WebPreviewCandidateService(
      negativeCacheTTL: 10,
      now: { clock.now() },
      evaluator: { projectPath in
        await spy.evaluate(projectPath: projectPath)
      }
    )

    let initial = await service.candidateStatus(for: "/tmp/project")
    clock.advance(by: 5)
    let cached = await service.candidateStatus(for: "/tmp/project")
    clock.advance(by: 6)
    let refreshed = await service.candidateStatus(for: "/tmp/project")
    let evaluationCount = await spy.evaluationCount

    #expect(initial == .notCandidate)
    #expect(cached == .notCandidate)
    #expect(refreshed == .candidate(reason: .staticEntry))
    #expect(evaluationCount == 2)
  }

  @Test("Cached negative status is available until the TTL expires")
  func cachedNegativeStatusIsAvailableUntilTTLExpires() async {
    let clock = TestClock(currentDate: Date(timeIntervalSince1970: 0))
    let service = WebPreviewCandidateService(
      negativeCacheTTL: 10,
      now: { clock.now() },
      evaluator: { _ in .notCandidate }
    )

    _ = await service.candidateStatus(for: "/tmp/project")
    let cachedBeforeExpiry = await service.cachedCandidateStatus(for: "/tmp/project")
    clock.advance(by: 11)
    let cachedAfterExpiry = await service.cachedCandidateStatus(for: "/tmp/project")

    #expect(cachedBeforeExpiry == .notCandidate)
    #expect(cachedAfterExpiry == nil)
  }
}

@Suite("WebPreviewCandidateVisibility")
struct WebPreviewCandidateVisibilityTests {

  @Test("Detected localhost always shows preview")
  func detectedLocalhostAlwaysShowsPreview() {
    let shouldShow = WebPreviewCandidateVisibility.shouldShow(
      candidateStatus: .notCandidate,
      detectedLocalhostURL: URL(string: "http://localhost:3000")
    )

    #expect(shouldShow == true)
  }

  @Test("Checking state does not show preview")
  func checkingStateDoesNotShowPreview() {
    let shouldShow = WebPreviewCandidateVisibility.shouldShow(
      candidateStatus: .checking,
      detectedLocalhostURL: nil
    )

    #expect(shouldShow == false)
  }
}

@Suite("CLISessionsViewModel Web Preview Candidates")
struct CLISessionsViewModelWebPreviewCandidateTests {

  @Test("ensureWebPreviewCandidate stores the resolved status")
  @MainActor
  func ensureWebPreviewCandidateStoresResolvedStatus() async {
    let candidateService = MockWebPreviewCandidateService(
      status: .candidate(reason: .knownFramework)
    )
    let viewModel = CLISessionsViewModel(
      monitorService: StubMonitorService(),
      fileWatcher: StubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      webPreviewCandidateService: candidateService,
      requestNotificationPermissionsOnInit: false
    )

    await viewModel.ensureWebPreviewCandidate(for: "/tmp/project")

    #expect(
      viewModel.webPreviewCandidateStatus(for: "/tmp/project")
        == .candidate(reason: .knownFramework)
    )
  }

  @Test("ensureWebPreviewCandidate uses the fresh cached status without rechecking")
  @MainActor
  func ensureWebPreviewCandidateUsesFreshCachedStatus() async {
    let candidateService = MockWebPreviewCandidateService(
      status: .candidate(reason: .knownFramework),
      cachedStatus: .notCandidate
    )
    let viewModel = CLISessionsViewModel(
      monitorService: StubMonitorService(),
      fileWatcher: StubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      webPreviewCandidateService: candidateService,
      requestNotificationPermissionsOnInit: false
    )

    await viewModel.ensureWebPreviewCandidate(for: "/tmp/project")

    #expect(viewModel.webPreviewCandidateStatus(for: "/tmp/project") == .notCandidate)
  }
}

@Suite("ProjectFileService web preview invalidation")
struct ProjectFileServiceWebPreviewInvalidationTests {

  @Test("Writes invalidate the preview candidate cache for the project")
  func writesInvalidatePreviewCandidateCache() async throws {
    let fixture = try WebPreviewCandidateFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("README.md", content: "before")
    let candidateService = MockWebPreviewCandidateService()
    let projectFileService = ProjectFileService(
      webPreviewCandidateService: candidateService
    )
    let filePath = fixture.root.appendingPathComponent("README.md").path

    try await projectFileService.writeFile(
      at: filePath,
      content: "after",
      projectPath: fixture.root.path
    )

    let invalidatedPaths = await candidateService.recordedInvalidations()
    #expect(invalidatedPaths == [fixture.root.path])
  }
}
