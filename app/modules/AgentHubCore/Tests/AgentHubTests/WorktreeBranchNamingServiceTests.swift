import Combine
import Foundation
import Testing

import ClaudeCodeClient
@testable import AgentHubCore

@Suite("ClaudeWorktreeBranchNamingService")
struct WorktreeBranchNamingServiceTests {

  @Test("AI result is sanitized, prefixed, and suffixed")
  func aiResultUsesSanitizedStem() async {
    let defaults = makeDefaults(prefix: "feature/")
    let recorder = InvocationRecorder()
    let service = makeService(
      defaults: defaults,
      recorder: recorder,
      publisher: chunkPublisher([
        decodeChunk(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\"Login Flow Cleanup\""}]}}"#),
        decodeChunk(#"{"type":"result","subtype":"success","result":"```login flow cleanup```"}"#)
      ])
    )

    let result = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "AgentHub",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .manualWorktree,
      promptText: "Please clean up the login flow",
      attachmentBasenames: [],
      providerKinds: [.claude]
    ))

    #expect(result.single == "feature/login-flow-cleanup-abcdef")
    #expect(result.source == .ai)

    let invocation = recorder.snapshot().last
    #expect(invocation?.model == "haiku")
    #expect(invocation?.workingDirectory == "/tmp/repo")
  }

  @Test("Dual-provider launch shares a base token and adds provider suffixes")
  func dualProviderNamesShareBase() async {
    let service = makeService(
      defaults: makeDefaults(prefix: "feature/"),
      publisher: chunkPublisher([
        decodeChunk(#"{"type":"result","subtype":"success","result":"parallel review"}"#)
      ])
    )

    let result = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "AgentHub",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .manualWorktree,
      promptText: "Review the launch flow in parallel",
      attachmentBasenames: [],
      providerKinds: [.claude, .codex]
    ))

    #expect(result.single == nil)
    #expect(result.claude == "feature/parallel-review-abcdef-claude")
    #expect(result.codex == "feature/parallel-review-abcdef-codex")
    #expect(result.source == .ai)
  }

  @Test("Empty context still invokes AI naming using repository metadata")
  func emptyContextUsesAIRepoContext() async {
    let recorder = InvocationRecorder()
    let service = makeService(
      defaults: makeDefaults(),
      recorder: recorder,
      publisher: chunkPublisher([
        decodeChunk(#"{"type":"result","subtype":"success","result":"canvas-session"}"#)
      ])
    )

    let result = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "Canvas",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .manualWorktree,
      promptText: "",
      attachmentBasenames: [],
      providerKinds: [.claude]
    ))

    #expect(result.single == "canvas-session-abcdef")
    #expect(result.source == .ai)
    #expect(recorder.snapshot().count == 1)
  }

  @Test("Missing Claude executable falls back deterministically")
  func missingExecutableFallsBack() async {
    let service = makeService(
      defaults: makeDefaults(prefix: "feature/"),
      publisher: Fail(error: ClaudeCodeClientError.notInstalled("claude"))
        .eraseToAnyPublisher()
    )

    let result = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "AgentHub",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .manualWorktree,
      promptText: "Fix launcher naming",
      attachmentBasenames: [],
      providerKinds: [.claude]
    ))

    #expect(result.single == "feature/fix-launcher-naming-abcdef")
    #expect(result.source == .deterministicFallback)
  }

  @Test("Empty context fallback uses repository name when Claude fails")
  func emptyContextFallbackUsesRepositoryName() async {
    let service = makeService(
      defaults: makeDefaults(prefix: "feature/"),
      publisher: Fail(error: ClaudeCodeClientError.notInstalled("claude"))
        .eraseToAnyPublisher()
    )

    let result = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "Canvas",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .manualWorktree,
      promptText: "",
      attachmentBasenames: [],
      providerKinds: [.claude]
    ))

    #expect(result.single == "feature/canvas-session-abcdef")
    #expect(result.source == .deterministicFallback)
  }

  @Test("Unusable AI output falls back deterministically")
  func unusableOutputFallsBack() async {
    let service = makeService(
      defaults: makeDefaults(),
      publisher: chunkPublisher([
        decodeChunk(#"{"type":"result","subtype":"success","result":"!!!"}"#)
      ])
    )

    let result = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "AgentHub",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .manualWorktree,
      promptText: "Name the new launch flow",
      attachmentBasenames: [],
      providerKinds: [.claude]
    ))

    #expect(result.single == "name-the-new-launch-abcdef")
    #expect(result.source == .deterministicFallback)
  }

  @Test("Smart fallback request sends smart-plan text when provided")
  func smartFallbackPromptUsesProvidedPlanText() async {
    let recorder = InvocationRecorder()
    let service = makeService(
      defaults: makeDefaults(),
      recorder: recorder,
      publisher: chunkPublisher([
        decodeChunk(#"{"type":"result","subtype":"success","result":"plan-rollout"}"#)
      ])
    )

    _ = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "AgentHub",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .smartFallback,
      promptText: "Detailed smart plan text",
      attachmentBasenames: ["Plan.md"],
      providerKinds: [.codex]
    ))

    let invocation = recorder.snapshot().last
    #expect(invocation?.prompt.contains("Detailed smart plan text") == true)
    #expect(invocation?.prompt.contains("Plan.md") == true)
    #expect(invocation?.prompt.contains("smartFallback") == true)
  }

  @Test("Retries with a supported Haiku model when the preferred model is unavailable")
  func retriesWithSupportedHaikuModel() async {
    let recorder = InvocationRecorder()
    let service = makeSequencedService(
      defaults: makeDefaults(),
      recorder: recorder,
      publishers: [
        failingChunkPublisher(
          [
            decodeChunk(#"{"type":"result","subtype":"success","result":"There's an issue with the selected model (haiku). It may not exist or you may not have access to it. Run --model to pick a different model."}"#)
          ],
          error: ClaudeCodeClientError.executionFailed("Process exited with status 1")
        ),
        failingChunkPublisher(
          [
            decodeChunk(#"{"type":"result","subtype":"success","result":"There's an issue with the selected model (claude-haiku-4-5). It may not exist or you may not have access to it. Run --model to pick a different model."}"#)
          ],
          error: ClaudeCodeClientError.executionFailed("Process exited with status 1")
        ),
        chunkPublisher([
          decodeChunk(#"{"type":"result","subtype":"success","result":"canvas-session"}"#)
        ])
      ]
    )

    let result = await service.resolveBranchNames(for: WorktreeBranchNamingRequest(
      repoName: "Canvas",
      repoPath: "/tmp/repo",
      baseBranchName: "main",
      launchContext: .manualWorktree,
      promptText: "",
      attachmentBasenames: [],
      providerKinds: [.claude]
    ))

    #expect(result.single == "canvas-session-abcdef")
    #expect(result.source == .ai)
    #expect(recorder.snapshot().map(\.model) == [
      "haiku",
      "claude-haiku-4-5",
      "claude-3-haiku-20240307"
    ])
  }

  @Test("Naming timeout falls back deterministically and cancels the in-flight client")
  func namingTimeoutFallsBackAndCancelsClient() async {
    let cancellationRecorder = CancellationRecorder()
    let subjectBox = StreamSubjectBox()
    let progressRecorder = NamingProgressRecorder()
    let service = makeService(
      defaults: makeDefaults(prefix: "feature/"),
      cancellationRecorder: cancellationRecorder,
      onCancel: {
        subjectBox.subject.send(completion: .failure(ClaudeCodeClientError.executionFailed("Cancelled")))
      },
      namingTimeout: .milliseconds(50),
      publisher: subjectBox.subject.eraseToAnyPublisher()
    )

    let result = await service.resolveBranchNames(
      for: WorktreeBranchNamingRequest(
        repoName: "Canvas",
        repoPath: "/tmp/repo",
        baseBranchName: "main",
        launchContext: .manualWorktree,
        promptText: "Investigate timeout path",
        attachmentBasenames: [],
        providerKinds: [.claude]
      ),
      onProgress: { progress in
        progressRecorder.record(progress)
      }
    )

    #expect(result.single == "feature/investigate-timeout-path-abcdef")
    #expect(result.source == WorktreeBranchNameSource.deterministicFallback)
    #expect(cancellationRecorder.snapshot() == 1)
    #expect(progressRecorder.lastProgress() == .completed(
      message: "Branch naming reached the 15-second limit, so AgentHub used a fallback name",
      source: .deterministicFallback,
      branchNames: ["feature/investigate-timeout-path-abcdef"]
    ))
  }
}

@Suite("WorktreeBranchNamingSettings")
struct WorktreeBranchNamingSettingsTests {

  @Test("Default prefix is empty")
  func defaultPrefixIsEmpty() {
    let defaults = makeDefaults()
    let settings = WorktreeBranchNamingSettings.load(from: defaults)
    #expect(settings.normalizedPrefix.isEmpty)
  }

  @Test("Stored prefix round-trips from defaults")
  func storedPrefixRoundTrips() {
    let defaults = makeDefaults(prefix: "feature/releases/")
    let settings = WorktreeBranchNamingSettings.load(from: defaults)
    #expect(settings.rawPrefix == "feature/releases/")
    #expect(settings.normalizedPrefix == "feature/releases/")
  }

  @Test("Prefix normalization and preview are deterministic")
  func prefixNormalizationIsDeterministic() {
    let settings = WorktreeBranchNamingSettings(rawPrefix: " Feature / Release Candidate ")
    #expect(settings.normalizedPrefix == "feature/release-candidate/")
    #expect(settings.previewBranchName(stem: "login-fix-abcdef") == "feature/release-candidate/login-fix-abcdef")
  }
}

private func makeService(
  defaults: UserDefaults,
  recorder: InvocationRecorder = InvocationRecorder(),
  cancellationRecorder: CancellationRecorder? = nil,
  onCancel: (@Sendable () -> Void)? = nil,
  namingTimeout: Duration = .seconds(15),
  publisher: AnyPublisher<StreamJSONChunk, Error>
) -> ClaudeWorktreeBranchNamingService {
  ClaudeWorktreeBranchNamingService(
    additionalPaths: [],
    defaults: defaults,
    clientFactory: { _, _ in
      MockClaudeCLIClient(
        recorder: recorder,
        cancellationRecorder: cancellationRecorder,
        onCancel: onCancel,
        publisher: publisher
      )
    },
    namingTimeout: namingTimeout,
    uuidProvider: { UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")! }
  )
}

private func makeSequencedService(
  defaults: UserDefaults,
  recorder: InvocationRecorder = InvocationRecorder(),
  publishers: [AnyPublisher<StreamJSONChunk, Error>]
) -> ClaudeWorktreeBranchNamingService {
  let publisherSource = SequencedPublisherSource(publishers: publishers)
  return ClaudeWorktreeBranchNamingService(
    additionalPaths: [],
    defaults: defaults,
    clientFactory: { _, _ in
      MockClaudeCLIClient(
        recorder: recorder,
        cancellationRecorder: nil,
        publisherProvider: {
          publisherSource.next()
        }
      )
    },
    uuidProvider: { UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")! }
  )
}

private func makeDefaults(prefix: String = "") -> UserDefaults {
  let suiteName = "com.agenthub.tests.worktree-branch-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  defaults.set(prefix, forKey: AgentHubDefaults.worktreeBranchPrefix)
  defaults.set("claude", forKey: AgentHubDefaults.claudeCommand)
  return defaults
}

private func chunkPublisher(_ chunks: [StreamJSONChunk]) -> AnyPublisher<StreamJSONChunk, Error> {
  chunks.publisher
    .setFailureType(to: Error.self)
    .eraseToAnyPublisher()
}

private func failingChunkPublisher(
  _ chunks: [StreamJSONChunk],
  error: Error
) -> AnyPublisher<StreamJSONChunk, Error> {
  chunks.publisher
    .setFailureType(to: Error.self)
    .append(Fail(error: error))
    .eraseToAnyPublisher()
}

private func decodeChunk(_ json: String) -> StreamJSONChunk {
  let decoder = JSONDecoder()
  return try! decoder.decode(StreamJSONChunk.self, from: Data(json.utf8))
}

private struct Invocation: Equatable {
  let prompt: String
  let workingDirectory: String
  let systemPrompt: String?
  let permissionMode: String?
  let disallowedTools: [String]?
  let model: String?
}

private final class CancellationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func record() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func snapshot() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private final class NamingProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var progressUpdates: [WorktreeBranchNamingProgress] = []

  func record(_ progress: WorktreeBranchNamingProgress) {
    lock.lock()
    progressUpdates.append(progress)
    lock.unlock()
  }

  func lastProgress() -> WorktreeBranchNamingProgress? {
    lock.lock()
    defer { lock.unlock() }
    return progressUpdates.last
  }
}

private final class StreamSubjectBox: @unchecked Sendable {
  let subject = PassthroughSubject<StreamJSONChunk, Error>()
}

private final class InvocationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var invocations: [Invocation] = []

  func append(_ invocation: Invocation) {
    lock.lock()
    invocations.append(invocation)
    lock.unlock()
  }

  func snapshot() -> [Invocation] {
    lock.lock()
    defer { lock.unlock() }
    return invocations
  }
}

private final class MockClaudeCLIClient: ClaudeCLIClientProtocol, @unchecked Sendable {
  private let recorder: InvocationRecorder
  private let cancellationRecorder: CancellationRecorder?
  private let onCancel: (@Sendable () -> Void)?
  private let publisherProvider: @Sendable () -> AnyPublisher<StreamJSONChunk, Error>

  init(
    recorder: InvocationRecorder,
    cancellationRecorder: CancellationRecorder? = nil,
    onCancel: (@Sendable () -> Void)? = nil,
    publisher: AnyPublisher<StreamJSONChunk, Error>
  ) {
    self.recorder = recorder
    self.cancellationRecorder = cancellationRecorder
    self.onCancel = onCancel
    self.publisherProvider = { publisher }
  }

  init(
    recorder: InvocationRecorder,
    cancellationRecorder: CancellationRecorder? = nil,
    onCancel: (@Sendable () -> Void)? = nil,
    publisherProvider: @escaping @Sendable () -> AnyPublisher<StreamJSONChunk, Error>
  ) {
    self.recorder = recorder
    self.cancellationRecorder = cancellationRecorder
    self.onCancel = onCancel
    self.publisherProvider = publisherProvider
  }

  func runStreamingPrompt(
    prompt: String,
    workingDirectory: String,
    systemPrompt: String?,
    permissionMode: String?,
    disallowedTools: [String]?,
    model: String?
  ) -> AnyPublisher<StreamJSONChunk, Error> {
    recorder.append(Invocation(
      prompt: prompt,
      workingDirectory: workingDirectory,
      systemPrompt: systemPrompt,
      permissionMode: permissionMode,
      disallowedTools: disallowedTools,
      model: model
    ))
    return publisherProvider()
  }

  @MainActor
  func cancel() {
    cancellationRecorder?.record()
    onCancel?()
  }
}

private final class SequencedPublisherSource: @unchecked Sendable {
  private let lock = NSLock()
  private var publishers: [AnyPublisher<StreamJSONChunk, Error>]

  init(publishers: [AnyPublisher<StreamJSONChunk, Error>]) {
    self.publishers = publishers
  }

  func next() -> AnyPublisher<StreamJSONChunk, Error> {
    lock.lock()
    defer { lock.unlock() }

    if publishers.isEmpty {
      return Fail(error: ClaudeCodeClientError.executionFailed("Missing test publisher"))
        .eraseToAnyPublisher()
    }

    return publishers.removeFirst()
  }
}
