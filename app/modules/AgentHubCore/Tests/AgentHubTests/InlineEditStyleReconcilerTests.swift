import Foundation
import Testing

@testable import AgentHubCore

@Suite("InlineEditStyleReconciler.sanitizeOutput")
struct InlineEditStyleReconcilerSanitizeTests {

  @Test("Plain output is returned trimmed")
  func plainOutputIsReturnedTrimmed() throws {
    let raw = "\n.cta {\n  color: red;\n}\n"
    let edited = ".cta { color: red; }"
    let sanitized = try ClaudeInlineEditStyleReconciler.sanitizeOutput(raw, editedContentLength: edited.count)
    #expect(sanitized == ".cta {\n  color: red;\n}")
  }

  @Test("Markdown-fenced output has fences stripped")
  func fencedOutputHasFencesStripped() throws {
    let raw = """
    ```css
    .cta {
      color: red;
    }
    ```
    """
    let sanitized = try ClaudeInlineEditStyleReconciler.sanitizeOutput(raw, editedContentLength: 80)
    #expect(sanitized == ".cta {\n  color: red;\n}")
  }

  @Test("Empty output throws emptyOutput")
  func emptyOutputThrows() {
    #expect(throws: InlineEditStyleReconcilerError.self) {
      _ = try ClaudeInlineEditStyleReconciler.sanitizeOutput("   \n  ", editedContentLength: 100)
    }
  }

  @Test("Refusal-style output is rejected")
  func refusalIsRejected() {
    let raw = "I cannot help with that request."
    #expect(throws: InlineEditStyleReconcilerError.self) {
      _ = try ClaudeInlineEditStyleReconciler.sanitizeOutput(raw, editedContentLength: 400)
    }
  }

  @Test("Output suspiciously shorter than edited content is rejected")
  func truncatedOutputIsRejected() {
    let raw = "}"
    #expect(throws: InlineEditStyleReconcilerError.self) {
      _ = try ClaudeInlineEditStyleReconciler.sanitizeOutput(raw, editedContentLength: 200)
    }
  }

  @Test("Output near the original length is accepted")
  func similarLengthOutputIsAccepted() throws {
    let raw = "body { background: white; padding: 4px; }"
    let sanitized = try ClaudeInlineEditStyleReconciler.sanitizeOutput(raw, editedContentLength: 45)
    #expect(sanitized == raw)
  }
}

@Suite("InlineEditStyleReconciler.reconcile")
struct InlineEditStyleReconcileTests {

  @Test("Forwards request fields to the programmatic service")
  func forwardsRequestFields() async throws {
    let recorder = ProgrammaticRequestRecorder()
    let service = StubProgrammaticService(
      recorder: recorder,
      response: .success("body { background: blue; }")
    )
    let reconciler = ClaudeInlineEditStyleReconciler(programmaticService: service)

    _ = try await reconciler.reconcile(
      originalContent: "body { background: red; }",
      editedContent: "body { background: blue; }",
      filePath: "/project/styles/main.css",
      changeSummary: "Set background to blue",
      projectPath: "/project"
    )

    let request = try #require(await recorder.snapshot().first)
    #expect(request.workingDirectory == "/project")
    #expect(request.models == ClaudeProgrammaticService.haikuFallbackModels)
    #expect(request.permissionMode == nil)
    #expect(request.userPrompt.contains("CHANGE: Set background to blue"))
    #expect(request.userPrompt.contains("ORIGINAL (/project/styles/main.css):"))
    #expect(request.userPrompt.contains("EDITED (/project/styles/main.css):"))
    #expect(request.userPrompt.contains("body { background: red; }"))
    #expect(request.userPrompt.contains("body { background: blue; }"))
    #expect(request.systemPrompt.contains("preserve the semantic change") || request.systemPrompt.contains("preserving the semantic change"))
  }

  @Test("Malformed underlying output bubbles up as a reconciler error")
  func malformedOutputBubblesUp() async {
    let service = StubProgrammaticService(
      recorder: ProgrammaticRequestRecorder(),
      response: .success("")
    )
    let reconciler = ClaudeInlineEditStyleReconciler(programmaticService: service)

    await #expect(throws: InlineEditStyleReconcilerError.self) {
      _ = try await reconciler.reconcile(
        originalContent: "body { background: red; }",
        editedContent: "body { background: blue; }",
        filePath: "/project/styles/main.css",
        changeSummary: "Set background to blue",
        projectPath: "/project"
      )
    }
  }
}

private actor ProgrammaticRequestRecorder {
  private var requests: [ClaudeProgrammaticRequest] = []

  func record(_ request: ClaudeProgrammaticRequest) {
    requests.append(request)
  }

  func snapshot() -> [ClaudeProgrammaticRequest] {
    requests
  }
}

private final class StubProgrammaticService: ClaudeProgrammaticServiceProtocol, @unchecked Sendable {
  enum Response: Sendable {
    case success(String)
    case failure(InlineEditStyleReconcilerError)
  }

  private let recorder: ProgrammaticRequestRecorder
  private let response: Response

  init(recorder: ProgrammaticRequestRecorder, response: Response) {
    self.recorder = recorder
    self.response = response
  }

  func run(
    _ request: ClaudeProgrammaticRequest,
    onModelAttempt: (@Sendable (String) -> Void)?
  ) async throws -> String {
    await recorder.record(request)
    if let firstModel = request.models.first {
      onModelAttempt?(firstModel)
    }
    switch response {
    case .success(let output):
      return output
    case .failure(let error):
      throw error
    }
  }

  func cancelActiveRequest() async {}
}
