import AppKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

// MARK: - Stubs

private actor ContextStubMonitorService: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private actor ContextStubFileWatcher: SessionFileWatcherProtocol {
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

// MARK: - Helpers

@MainActor
private func makeSessionsViewModel(provider: SessionProviderKind = .claude) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: ContextStubMonitorService(),
    fileWatcher: ContextStubFileWatcher(),
    searchService: nil,
    cliConfiguration: provider == .claude
      ? CLICommandConfiguration(command: "claude", mode: .claude)
      : CLICommandConfiguration(command: "codex", mode: .codex),
    providerKind: provider,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

@MainActor
private func makeLaunchViewModel(
  profileService: MockContextProfileService? = nil,
  payloadStore: any ContextPayloadStoring = ContextPayloadStore(),
  repositoryPath: String? = nil
) -> MultiSessionLaunchViewModel {
  let viewModel = MultiSessionLaunchViewModel(
    claudeViewModel: makeSessionsViewModel(),
    codexViewModel: makeSessionsViewModel(),
    contextProfileService: profileService,
    contextPayloadStore: payloadStore
  )
  if let repositoryPath {
    viewModel.selectedRepository = SelectedRepository(path: repositoryPath)
  }
  return viewModel
}

private func withTempProject(_ body: (URL) async throws -> Void) async throws {
  let project = FileManager.default.temporaryDirectory
    .appendingPathComponent("launch-context-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: project) }
  try await body(project)
}

private func write(_ relativePath: String, _ content: String, in project: URL) throws {
  let url = project.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try content.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Out-of-band context routing

@MainActor
@Suite("Launch context routing")
struct LaunchContextRoutingTests {
  private func makeWorktree() -> WorktreeBranch {
    WorktreeBranch(name: "main", path: "/tmp/project", isWorktree: false)
  }

  @Test("Claude: context rides the pending session, the first prompt stays pure")
  func claudeContextNeverMergesIntoPrompt() throws {
    let viewModel = makeSessionsViewModel()

    viewModel.startNewSessionInHub(
      makeWorktree(),
      initialPrompt: "fix the bug",
      contextBlock: "<context>x</context>"
    )

    let pending = try #require(viewModel.pendingHubSessions.first)
    #expect(pending.launchContext == "<context>x</context>")
    // Claude receives its prompt via the terminal paste — context must not be in it.
    #expect(pending.initialPrompt == nil)
    let pasted = viewModel.consumePendingPrompt(for: "pending-\(pending.id.uuidString)")
    #expect(pasted == "fix the bug")
  }

  @Test("Claude: context-only launch types nothing into the terminal")
  func claudeContextOnlyLaunchHasNoFirstMessage() throws {
    let viewModel = makeSessionsViewModel()

    viewModel.startNewSessionInHub(makeWorktree(), contextBlock: "<context>x</context>")

    let pending = try #require(viewModel.pendingHubSessions.first)
    #expect(pending.launchContext == "<context>x</context>")
    #expect(pending.initialPrompt == nil)
    #expect(viewModel.consumePendingPrompt(for: "pending-\(pending.id.uuidString)") == nil)
  }

  @Test("Codex: context rides the pending session, argv prompt stays pure")
  func codexContextNeverMergesIntoPrompt() throws {
    let viewModel = makeSessionsViewModel(provider: .codex)

    viewModel.startNewSessionInHub(
      makeWorktree(),
      initialPrompt: "fix the bug",
      contextBlock: "<context>x</context>"
    )

    let pending = try #require(viewModel.pendingHubSessions.first)
    #expect(pending.launchContext == "<context>x</context>")
    // Codex receives its prompt as a positional argv argument — context must not be in it.
    #expect(pending.initialPrompt == "fix the bug")
    #expect(viewModel.consumePendingPrompt(for: "pending-\(pending.id.uuidString)") == nil)
  }

  @Test("Whitespace-only context launches byte-identical to no context")
  func whitespaceContextIsDropped() throws {
    let viewModel = makeSessionsViewModel()

    viewModel.startNewSessionInHub(makeWorktree(), initialPrompt: "fix the bug", contextBlock: "  \n ")

    let pending = try #require(viewModel.pendingHubSessions.first)
    #expect(pending.launchContext == nil)
    #expect(viewModel.consumePendingPrompt(for: "pending-\(pending.id.uuidString)") == "fix the bug")
  }
}

@MainActor
@Suite("Combined append-system-prompt")
struct CombinedAppendSystemPromptTests {
  @Test("Nil pieces collapse to nil")
  func allNilIsNil() {
    #expect(EmbeddedTerminalLaunchBuilder.combinedAppendSystemPrompt(
      simulatorGuidance: nil, launchContext: nil) == nil)
    #expect(EmbeddedTerminalLaunchBuilder.combinedAppendSystemPrompt(
      simulatorGuidance: nil, launchContext: "  \n ") == nil)
  }

  @Test("Guidance alone passes through unchanged")
  func guidanceAlone() {
    let combined = EmbeddedTerminalLaunchBuilder.combinedAppendSystemPrompt(
      simulatorGuidance: "verify in the simulator", launchContext: nil)
    #expect(combined == "verify in the simulator")
  }

  @Test("Context alone gets the provenance preamble")
  func contextAlone() {
    let combined = EmbeddedTerminalLaunchBuilder.combinedAppendSystemPrompt(
      simulatorGuidance: nil, launchContext: "<context>x</context>")
    #expect(combined == EmbeddedTerminalLaunchBuilder.launchContextPreamble + "\n<context>x</context>")
  }

  @Test("Guidance comes first, then the context block")
  func guidanceThenContext() {
    let combined = EmbeddedTerminalLaunchBuilder.combinedAppendSystemPrompt(
      simulatorGuidance: "verify in the simulator", launchContext: "<context>x</context>")
    #expect(combined == "verify in the simulator\n\n"
      + EmbeddedTerminalLaunchBuilder.launchContextPreamble + "\n<context>x</context>")
  }
}

// MARK: - Launch view model context state

@MainActor
@Suite("Launch view model context")
struct MultiSessionLaunchContextTests {

  @Test("No selection resolves to no context block")
  func noSelectionResolvesNil() async {
    let viewModel = makeLaunchViewModel(repositoryPath: "/tmp/project")
    #expect(await viewModel.resolveContextBlock(repoPath: "/tmp/project") == nil)
  }

  @Test("Curated selection resolves to an assembled block and records missing paths")
  func curatedSelectionResolves() async throws {
    try await withTempProject { project in
      try write("src/a.swift", "let a = 1", in: project)
      let viewModel = makeLaunchViewModel(repositoryPath: project.path)
      viewModel.applyCuratedContext(ContextSelection(
        files: [
          ContextFileSelection(relativePath: "src/a.swift"),
          ContextFileSelection(relativePath: "gone.swift"),
        ],
        instructions: "Careful."
      ))

      let block = try #require(await viewModel.resolveContextBlock(repoPath: project.path))

      #expect(block.contains("<file path=\"src/a.swift\">\nlet a = 1\n</file>"))
      #expect(block.contains("gone.swift (missing)"))
      #expect(block.contains("<instructions>\nCareful.\n</instructions>"))
      #expect(viewModel.contextMissingPaths == ["gone.swift"])
    }
  }

  @Test("External files inline as text or ride along as attachment paths")
  func externalFilesResolve() async throws {
    try await withTempProject { project in
      try write("src/a.swift", "let a = 1", in: project)
      let outside = project.deletingLastPathComponent()
        .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: outside) }
      let notes = outside.appendingPathComponent("notes.md")
      try "external knowledge".write(to: notes, atomically: true, encoding: .utf8)
      let pdf = outside.appendingPathComponent("book.pdf")
      try Data([0x25, 0x50, 0x44, 0x46, 0xFF]).write(to: pdf)

      let viewModel = makeLaunchViewModel(repositoryPath: project.path)
      viewModel.applyCuratedContext(ContextSelection(
        files: [ContextFileSelection(relativePath: "src/a.swift")],
        externalPaths: [notes.path, pdf.path]
      ))

      let block = try #require(await viewModel.resolveContextBlock(repoPath: project.path))

      #expect(block.contains("<file path=\"\(notes.path)\">\nexternal knowledge\n</file>"))
      #expect(block.contains("\(pdf.path) (attachment — read separately)"))
      #expect(block.contains("<file path=\"src/a.swift\">"))
      #expect(viewModel.contextMissingPaths.isEmpty)
    }
  }

  @Test("Text snippets are assembled into the launch block")
  func textSnippetsResolve() async throws {
    try await withTempProject { project in
      let viewModel = makeLaunchViewModel(repositoryPath: project.path)
      viewModel.applyCuratedContext(ContextSelection(
        textSnippets: [ContextTextSnippet(title: "House rules", content: "Always run tests.")]
      ))

      let block = try #require(await viewModel.resolveContextBlock(repoPath: project.path))

      #expect(block.contains("<snippet title=\"House rules\">\nAlways run tests.\n</snippet>"))
      #expect(block.contains("House rules (pasted text)"))
    }
  }

  @Test("An oversized block resolves to a temp-file reference prompt")
  func oversizedBlockUsesFileReference() async throws {
    try await withTempProject { project in
      try write("big.txt", String(repeating: "x", count: 4_000), in: project)
      let payloadDirectory = project.appendingPathComponent("payloads", isDirectory: true)
      let viewModel = makeLaunchViewModel(
        payloadStore: ContextPayloadStore(directoryURL: payloadDirectory, inlineByteThreshold: 512),
        repositoryPath: project.path
      )
      viewModel.applyCuratedContext(ContextSelection(
        files: [ContextFileSelection(relativePath: "big.txt")]
      ))

      let block = try #require(await viewModel.resolveContextBlock(repoPath: project.path))

      #expect(block.contains("Read that file before doing anything else."))
      #expect(!block.contains(String(repeating: "x", count: 100)))
    }
  }

  @Test("The project default profile attaches once, and never after removal")
  func defaultProfileAttachesOnce() async {
    let service = MockContextProfileService()
    service.defaultProfileResult = makeProfile(id: "default", name: "Default", isDefault: true)
    let viewModel = makeLaunchViewModel(profileService: service, repositoryPath: "/tmp/project")

    await viewModel.loadDefaultContextProfile()
    #expect(viewModel.attachedContextProfile?.id == "default")

    viewModel.removeAttachedContextProfile()
    await viewModel.loadDefaultContextProfile()
    #expect(viewModel.attachedContextProfile == nil)
    #expect(viewModel.activeContextSelection == nil)
  }

  @Test("Ad-hoc curation overrides the attached profile")
  func curationOverridesProfile() async {
    let service = MockContextProfileService()
    service.defaultProfileResult = makeProfile(id: "default", name: "Default", isDefault: true)
    let viewModel = makeLaunchViewModel(profileService: service, repositoryPath: "/tmp/project")
    await viewModel.loadDefaultContextProfile()

    let curated = ContextSelection(files: [ContextFileSelection(relativePath: "only.swift")])
    viewModel.applyCuratedContext(curated)

    #expect(viewModel.activeContextSelection == curated)
  }

  @Test("Context summary estimates tokens and flags missing files without loading contents")
  func summaryEstimatesTokens() async throws {
    try await withTempProject { project in
      try write("a.swift", String(repeating: "a", count: 400), in: project)
      let viewModel = makeLaunchViewModel(repositoryPath: project.path)
      viewModel.applyCuratedContext(ContextSelection(
        files: [
          ContextFileSelection(relativePath: "a.swift"),
          ContextFileSelection(relativePath: "gone.swift"),
        ]
      ))

      await viewModel.refreshContextSummary()

      // 400 bytes / 4 × 1.15 = 115.
      #expect(viewModel.contextSummaryTokens == 115)
      #expect(viewModel.contextMissingPaths == ["gone.swift"])
    }
  }

  @Test("Switching repositories drops the previous repo's context state")
  func repoSwitchDropsContext() async {
    let service = MockContextProfileService()
    service.defaultProfileResult = makeProfile(id: "default", name: "Default", isDefault: true)
    let viewModel = makeLaunchViewModel(profileService: service, repositoryPath: "/tmp/project-a")
    await viewModel.loadDefaultContextProfile()
    #expect(viewModel.attachedContextProfile?.id == "default")

    viewModel.selectedRepository = SelectedRepository(path: "/tmp/project-b")

    #expect(viewModel.attachedContextProfile == nil)
    #expect(viewModel.pendingContextSelection == nil)
    #expect(viewModel.contextMissingPaths.isEmpty)
    #expect(viewModel.contextSummaryTokens == nil)
  }

  @Test("Removing the chip in one repo does not suppress the next repo's default")
  func chipRemovalDoesNotLeakAcrossRepos() async {
    let service = MockContextProfileService()
    service.defaultProfileResult = makeProfile(id: "default", name: "Default", isDefault: true)
    let viewModel = makeLaunchViewModel(profileService: service, repositoryPath: "/tmp/project-a")
    await viewModel.loadDefaultContextProfile()
    viewModel.removeAttachedContextProfile()
    #expect(viewModel.attachedContextProfile == nil)

    viewModel.selectedRepository = SelectedRepository(path: "/tmp/project-b")
    await viewModel.loadDefaultContextProfile()

    #expect(viewModel.attachedContextProfile?.id == "default")
  }

  @Test("Ad-hoc curation does not survive a repository switch")
  func adHocCurationDoesNotSurviveRepoSwitch() {
    let viewModel = makeLaunchViewModel(repositoryPath: "/tmp/project-a")
    viewModel.applyCuratedContext(
      ContextSelection(files: [ContextFileSelection(relativePath: "a.swift")]))
    #expect(viewModel.activeContextSelection != nil)

    viewModel.selectedRepository = SelectedRepository(path: "/tmp/project-b")
    #expect(viewModel.activeContextSelection == nil)
  }

  @Test("Attaching a saved set restores its identity over ad-hoc curation")
  func attachProfileKeepsIdentity() {
    let viewModel = makeLaunchViewModel(repositoryPath: "/tmp/project")
    viewModel.applyCuratedContext(
      ContextSelection(files: [ContextFileSelection(relativePath: "x.swift")]))
    let profile = makeProfile(id: "named", name: "Named")

    viewModel.attachContextProfile(profile)

    #expect(viewModel.attachedContextProfile?.id == "named")
    #expect(viewModel.pendingContextSelection == nil)
    #expect(viewModel.activeContextSelection == profile.selection)
  }

  @Test("Binary project files summarize and resolve as attachments, not missing")
  func binaryProjectFileIsAttachment() async throws {
    try await withTempProject { project in
      try Data([0x25, 0x50, 0x44, 0x46, 0xFF]).write(
        to: project.appendingPathComponent("spec.pdf"))
      let viewModel = makeLaunchViewModel(repositoryPath: project.path)
      viewModel.applyCuratedContext(
        ContextSelection(files: [ContextFileSelection(relativePath: "spec.pdf")]))

      await viewModel.refreshContextSummary()
      #expect(viewModel.contextMissingPaths.isEmpty)

      let block = try #require(await viewModel.resolveContextBlock(repoPath: project.path))
      #expect(block.contains("spec.pdf (attachment — read separately)"))
      #expect(!block.contains("spec.pdf (missing)"))
    }
  }

  @Test("Reset clears all context state")
  func resetClearsContext() async {
    let service = MockContextProfileService()
    service.defaultProfileResult = makeProfile(id: "default", name: "Default", isDefault: true)
    let viewModel = makeLaunchViewModel(profileService: service, repositoryPath: "/tmp/project")
    await viewModel.loadDefaultContextProfile()

    viewModel.reset()

    #expect(viewModel.attachedContextProfile == nil)
    #expect(viewModel.pendingContextSelection == nil)
    #expect(viewModel.contextMissingPaths.isEmpty)
  }
}

// MARK: - Terminal submit delay tiers

@MainActor
@Suite("Terminal prompt submit delay")
struct TerminalPromptSubmitDelayTests {
  @Test("Delay scales with payload size, topping out at one second")
  func delayTiers() {
    #expect(TerminalContainerView.submitDelay(forByteCount: 100) == .milliseconds(100))
    #expect(TerminalContainerView.submitDelay(forByteCount: 1_000) == .milliseconds(250))
    #expect(TerminalContainerView.submitDelay(forByteCount: 10_000) == .milliseconds(500))
    #expect(TerminalContainerView.submitDelay(forByteCount: 50_000) == .seconds(1))
  }
}
