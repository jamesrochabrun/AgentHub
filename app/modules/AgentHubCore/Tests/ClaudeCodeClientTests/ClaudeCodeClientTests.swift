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

private func awaitOutputs<Output>(
  from publisher: AnyPublisher<Output, Error>
) async -> ([Output], Subscribers.Completion<Error>) {
  let box = CancellableBox()
  return await withCheckedContinuation { continuation in
    var outputs: [Output] = []
    box.cancellable = publisher.sink(
      receiveCompletion: { completion in
        box.cancellable = nil
        continuation.resume(returning: (outputs, completion))
      },
      receiveValue: { output in
        outputs.append(output)
      }
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
      disallowedTools: nil,
      model: nil
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

  @Test("Model override appends --model flag")
  func modelOverrideAppendsFlag() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-client-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let argsFile = tempDir.appendingPathComponent("args.txt")
    let scriptURL = tempDir.appendingPathComponent("mock-claude.sh")
    let escapedArgsPath = argsFile.path.replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    #!/bin/sh
    printf '%s\n' "$@" > "\(escapedArgsPath)"
    cat >/dev/null
    printf '{"type":"result","subtype":"success","result":"named-branch"}\n'
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let client = ClaudeCLIClient(command: scriptURL.path)
    let (_, completion) = await awaitOutputs(from: client.runStreamingPrompt(
      prompt: "hello",
      workingDirectory: "",
      systemPrompt: nil,
      permissionMode: nil,
      disallowedTools: nil,
      model: "claude-haiku-4-20250514"
    ))

    guard case .finished = completion else {
      Issue.record("Expected successful completion, got \(completion)")
      return
    }

    let capturedArgs = try String(contentsOf: argsFile, encoding: .utf8)
      .components(separatedBy: .newlines)
      .filter { !$0.isEmpty }

    guard let modelIndex = capturedArgs.firstIndex(of: "--model") else {
      Issue.record("Expected --model flag in \(capturedArgs)")
      return
    }

    #expect(capturedArgs[modelIndex + 1] == "claude-haiku-4-20250514")
  }

  @Test("No model override preserves existing args")
  func noModelOverrideDoesNotAppendFlag() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-client-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let argsFile = tempDir.appendingPathComponent("args.txt")
    let scriptURL = tempDir.appendingPathComponent("mock-claude.sh")
    let escapedArgsPath = argsFile.path.replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    #!/bin/sh
    printf '%s\n' "$@" > "\(escapedArgsPath)"
    cat >/dev/null
    printf '{"type":"result","subtype":"success","result":"named-branch"}\n'
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let client = ClaudeCLIClient(command: scriptURL.path)
    let (_, completion) = await awaitOutputs(from: client.runStreamingPrompt(
      prompt: "hello",
      workingDirectory: "",
      systemPrompt: nil,
      permissionMode: nil,
      disallowedTools: nil,
      model: nil
    ))

    guard case .finished = completion else {
      Issue.record("Expected successful completion, got \(completion)")
      return
    }

    let capturedArgs = try String(contentsOf: argsFile, encoding: .utf8)
      .components(separatedBy: .newlines)
      .filter { !$0.isEmpty }

    #expect(!capturedArgs.contains("--model"))
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
