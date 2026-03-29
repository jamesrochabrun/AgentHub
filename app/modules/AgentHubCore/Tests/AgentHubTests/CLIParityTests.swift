import Combine
import Foundation
import Testing

@testable import AgentHubCore

private final class CancellableBox: @unchecked Sendable {
  var cancellable: AnyCancellable?
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private func awaitCompletion<Output>(
  from publisher: AnyPublisher<Output, Error>
) async -> Subscribers.Completion<Error> {
  let box = CancellableBox()
  return await withCheckedContinuation { continuation in
    box.cancellable = publisher.sink(
      receiveCompletion: { completion in
        box.cancellable = nil
        continuation.resume(returning: completion)
      },
      receiveValue: { _ in }
    )
  }
}

@Suite("CLIProcessService")
struct CLIProcessServiceTests {

  @Test("Missing executable fails before stream timeout")
  func missingExecutableFailsImmediately() async {
    let command = "agenthub-missing-\(UUID().uuidString)"
    let service = CLIProcessService(command: command)

    let completion = await awaitCompletion(from: service.runStreamingPrompt(
      prompt: "hello",
      workingDirectory: "",
      systemPrompt: nil,
      permissionMode: nil,
      disallowedTools: nil
    ))

    guard case .failure(let error) = completion else {
      Issue.record("Expected failure completion, got \(completion)")
      return
    }

    guard let processError = error as? CLIProcessError,
          case .notInstalled(let missingCommand) = processError else {
      Issue.record("Expected notInstalled error, got \(error.localizedDescription)")
      return
    }

    #expect(missingCommand == command)
  }
}

@Suite("IntelligenceStreamProcessor")
struct IntelligenceStreamProcessorTests {

  @Test("Timeout cancels upstream subscription")
  @MainActor
  func timeoutCancelsSubscription() async {
    let processor = IntelligenceStreamProcessor(timeoutNanoseconds: 5_000_000)
    let cancelFlag = LockedFlag()
    let subject = PassthroughSubject<StreamJSONChunk, Error>()
    let publisher = subject
      .handleEvents(receiveCancel: { cancelFlag.set() })
      .eraseToAnyPublisher()
    var receivedError: Error?

    processor.onError = { receivedError = $0 }

    await processor.processStream(publisher)

    #expect(cancelFlag.get())

    guard let processError = receivedError as? CLIProcessError,
          case .timeout(let seconds) = processError else {
      Issue.record("Expected timeout error, got \(String(describing: receivedError))")
      return
    }

    #expect(seconds < 1)
  }
}

@Suite("CLIPathResolver")
struct CLIPathResolverTests {

  @Test("Claude paths include SDK-era tool directories once")
  func claudePathsIncludeSharedToolDirectories() {
    let home = "/tmp/agenthub-home"
    let paths = CLIPathResolver.claudePaths(
      additionalPaths: ["/custom/bin", "\(home)/.cargo/bin"],
      homeDirectory: home
    )

    #expect(paths.first == "\(home)/.claude/local")
    #expect(paths.contains("/custom/bin"))
    #expect(paths.contains("\(home)/.bun/bin"))
    #expect(paths.contains("\(home)/.deno/bin"))
    #expect(paths.contains("\(home)/.cargo/bin"))
    #expect(paths.filter { $0 == "\(home)/.cargo/bin" }.count == 1)
  }

  @Test("Executable search paths keep launcher parity")
  func executableSearchPathsIncludeSharedFallbacks() {
    let home = "/tmp/agenthub-home"
    let paths = CLIPathResolver.executableSearchPaths(homeDirectory: home)

    #expect(paths.contains("\(home)/.claude/local"))
    #expect(paths.contains("\(home)/.bun/bin"))
    #expect(paths.contains("\(home)/.deno/bin"))
    #expect(paths.contains("\(home)/.cargo/bin"))
  }
}
