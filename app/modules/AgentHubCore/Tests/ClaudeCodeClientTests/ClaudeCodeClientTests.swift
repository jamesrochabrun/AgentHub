import Combine
import Foundation
import Testing

@testable import ClaudeCodeClient

private final class CancellableBox: @unchecked Sendable {
  var cancellable: AnyCancellable?
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

@Suite("ClaudeCLIClient")
struct ClaudeCLIClientTests {

  @Test("Missing executable fails before stream timeout")
  func missingExecutableFailsImmediately() async {
    let command = "agenthub-missing-\(UUID().uuidString)"
    let client = ClaudeCLIClient(command: command)

    let completion = await awaitCompletion(from: client.runStreamingPrompt(
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

    guard let clientError = error as? ClaudeCodeClientError,
          case .notInstalled(let missingCommand) = clientError else {
      Issue.record("Expected notInstalled error, got \(error.localizedDescription)")
      return
    }

    #expect(missingCommand == command)
  }
}

@Suite("ClaudeCodePathResolver")
struct ClaudeCodePathResolverTests {

  @Test("Search paths include SDK-era tool directories once")
  func searchPathsIncludeSharedToolDirectories() {
    let home = "/tmp/agenthub-home"
    let paths = ClaudeCodePathResolver.searchPaths(
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
}

@Suite("StreamJSONTypes")
struct StreamJSONTypesTests {

  @Test("Assistant and user roles decode as enums")
  func assistantAndUserRolesDecodeAsEnums() throws {
    let decoder = JSONDecoder()

    let assistantChunk = try decoder.decode(
      StreamJSONChunk.self,
      from: Data(
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#.utf8
      )
    )
    let userChunk = try decoder.decode(
      StreamJSONChunk.self,
      from: Data(
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"done"}]}}"#.utf8
      )
    )

    guard case .assistant(let assistantMessage) = assistantChunk else {
      Issue.record("Expected assistant chunk")
      return
    }
    guard case .user(let userMessage) = userChunk else {
      Issue.record("Expected user chunk")
      return
    }

    #expect(assistantMessage.type == .assistant)
    #expect(assistantMessage.message.role == .assistant)
    #expect(userMessage.type == .user)
    #expect(userMessage.message.role == .user)
  }

  @Test("Unknown raw values remain decodable")
  func unknownRawValuesRemainDecodable() throws {
    let decoder = JSONDecoder()
    let chunk = try decoder.decode(
      StreamJSONChunk.self,
      from: Data(#"{"type":"assistant","message":{"role":"reviewer","content":[{"type":"annotation","text":"note"}]}}"#.utf8)
    )

    guard case .assistant(let message) = chunk else {
      Issue.record("Expected assistant chunk")
      return
    }

    #expect(message.message.role == .unknown("reviewer"))

    guard case .unknown = message.message.content.first else {
      Issue.record("Expected unknown content block")
      return
    }
  }
}
