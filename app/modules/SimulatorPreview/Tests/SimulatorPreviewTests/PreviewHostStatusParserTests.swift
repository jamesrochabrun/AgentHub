import Testing

@testable import SimulatorPreview

@Suite("PreviewHostStatusParser")
struct PreviewHostStatusParserTests {

  private let parser = PreviewHostStatusParser()

  @Test("waiting for foreground")
  func waiting() {
    #expect(
      parser.parse(line: "AGENTHUB_PREVIEW_HOST: waiting reason=app-not-active")
        == .waitingForForeground
    )
  }

  @Test("listening with port")
  func listening() {
    #expect(
      parser.parse(line: "AGENTHUB_PREVIEW_HOST: listening port=38712")
        == .listening(port: 38712)
    )
  }

  @Test("unsupported OS version")
  func unsupported() {
    let status = parser.parse(
      line: "AGENTHUB_PREVIEW_HOST: unsupported reason=ios-version")
    guard case .failed(reason: .unsupportedOSVersion, _)? = status else {
      Issue.record("expected unsupported-OS failure, got \(String(describing: status))")
      return
    }
  }

  @Test("port in use")
  func portInUse() {
    #expect(
      parser.parse(line: "AGENTHUB_PREVIEW_HOST: failed reason=port-in-use port=38701")
        == .failed(reason: .portInUse(port: 38701), detail: "")
    )
  }

  @Test("server error carries the trailing detail verbatim")
  func serverError() {
    let status = parser.parse(
      line: "AGENTHUB_PREVIEW_HOST: failed reason=server-error "
        + "detail=SocketError.failed(type: bind, errno: 13)")
    #expect(status == .failed(
      reason: .serverError,
      detail: "SocketError.failed(type: bind, errno: 13)"
    ))
  }

  @Test("non-status lines are ignored")
  func ignoresOtherLines() {
    #expect(parser.parse(line: "🔥 ✅ Hot reload complete") == nil)
    #expect(parser.parse(line: "AgentHubPreviewHost: serving previews") == nil)
    #expect(parser.parse(line: "") == nil)
  }

  @Test("malformed status lines are ignored, not misread")
  func malformed() {
    #expect(parser.parse(line: "AGENTHUB_PREVIEW_HOST: listening") == nil)
    #expect(parser.parse(line: "AGENTHUB_PREVIEW_HOST: listening port=abc") == nil)
    #expect(parser.parse(line: "AGENTHUB_PREVIEW_HOST: failed reason=port-in-use") == nil)
    #expect(parser.parse(line: "AGENTHUB_PREVIEW_HOST: failed reason=mystery") == nil)
    #expect(parser.parse(line: "AGENTHUB_PREVIEW_HOST: exploded") == nil)
  }
}
