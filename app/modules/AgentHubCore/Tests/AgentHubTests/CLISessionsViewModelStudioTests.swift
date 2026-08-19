import AgentHubCLIKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

private final class StudioViewModelMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<[SelectedRepository], Never>()
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> { subject.eraseToAnyPublisher() }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class StudioViewModelFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> { subject.eraseToAnyPublisher() }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

/// The glue between the handler and the shared library: both provider view
/// models file into one `StudioLibrary`, keyed by project, so a canvas from
/// Codex is on screen for a Claude session in the same repo.
@Suite("CLISessionsViewModel Studio")
struct CLISessionsViewModelStudioTests {
  @MainActor
  private func makeViewModel(provider: SessionProviderKind, library: StudioLibrary) -> CLISessionsViewModel {
    let vm = CLISessionsViewModel(
      monitorService: StudioViewModelMonitorService(),
      fileWatcher: StudioViewModelFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(
        command: provider == .codex ? "codex" : "claude",
        mode: provider == .codex ? .codex : .claude
      ),
      providerKind: provider,
      approvalNotificationService: NoOpApprovalNotificationService()
    )
    vm.studioLibrary = library
    return vm
  }

  @MainActor
  private func makeLibrary() throws -> (StudioLibrary, URL) {
    let root = try temporaryStudioRoot()
    let library = StudioLibrary(
      persistence: StudioPersistenceMock(),
      documents: StudioDocumentWriter(rootURL: root.appendingPathComponent("docs")),
      server: StudioServerMock(),
      index: StudioIndexStore(directoryURL: root.appendingPathComponent("index"))
    )
    return (library, root)
  }

  @MainActor
  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("An artifact filed from a Codex session shows for a Claude session in the same project")
  @MainActor
  func sharedAcrossProviders() async throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let claude = makeViewModel(provider: .claude, library: library)
    let codex = makeViewModel(provider: .codex, library: library)
    let claudeSession = CLISession(id: "claude-1", projectPath: "/tmp/proj/")
    let codexSession = CLISession(id: "codex-1", projectPath: "/tmp/proj")

    #expect(!claude.hasStudioArtifacts(for: claudeSession))
    codex.storeStudioArtifact(makeStudioCanvas(id: "c1", provider: .codex, sessionId: "codex-1", projectPath: "/tmp/proj"), forSessionId: "codex-1")
    await waitUntil { claude.hasStudioArtifacts(for: claudeSession) }

    #expect(claude.studioArtifacts(for: claudeSession).map(\.id) == ["c1"])
    #expect(codex.studioArtifacts(for: codexSession).map(\.id) == ["c1"])
    #expect(claude.projectScopeKey(for: claudeSession) == codex.projectScopeKey(for: codexSession))
  }

  @Test("Re-filing under the same id replaces in place; delete removes it for every session")
  @MainActor
  func refileAndDelete() async throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let vm = makeViewModel(provider: .claude, library: library)
    let session = CLISession(id: "s1", projectPath: "/tmp/proj")

    vm.storeStudioArtifact(makeStudioDocument(id: "d1", title: "v1", projectPath: "/tmp/proj"), forSessionId: "s1")
    await waitUntil { vm.hasStudioArtifacts(for: session) }
    vm.storeStudioArtifact(makeStudioDocument(id: "d1", title: "v2", createdAt: Date(timeIntervalSince1970: 5_000), projectPath: "/tmp/proj"), forSessionId: "s1")
    await waitUntil { vm.studioArtifacts(for: session).first?.title == "v2" }

    let stored = vm.studioArtifacts(for: session)
    #expect(stored.count == 1)
    #expect(stored.first?.revision == 2)
    #expect(stored.first?.createdAt == Date(timeIntervalSince1970: 1_000))

    vm.deleteStudioArtifact(id: "d1", in: session)
    await waitUntil { !vm.hasStudioArtifacts(for: session) }
    #expect(!vm.hasStudioArtifacts(for: session))
  }

  @Test("An artifact with no resolvable project is dropped, not stored under an empty key")
  @MainActor
  func dropsWithoutProject() async throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let vm = makeViewModel(provider: .claude, library: library)

    vm.storeStudioArtifact(makeStudioCanvas(id: "c1", projectPath: nil), forSessionId: "unknown-session")
    try await Task.sleep(for: .milliseconds(100))

    #expect(library.artifactsByProject.isEmpty)
  }
}
