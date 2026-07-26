import Testing

@testable import AgentHubCLIKit

@Suite("SessionNameFormatter")
struct SessionNameFormatterTests {
  @Test("Converts names to lowercase kebab case")
  func convertsNamesToKebabCase() {
    #expect(SessionNameFormatter.format("Session naming test") == "session-naming-test")
    #expect(SessionNameFormatter.format("  Fix_auth / Flow  ") == "fix-auth-flow")
    #expect(SessionNameFormatter.format("Résumé Polish") == "resume-polish")
  }

  @Test("Limits names without leaving a trailing separator")
  func limitsNames() {
    let formatted = SessionNameFormatter.format(
      "implement a deliberately verbose session naming workflow with unnecessary extra details"
    )

    #expect(formatted == "implement-a-deliberately-verbose-session-naming")
    #expect(formatted?.count ?? 0 <= SessionNameFormatter.maximumLength)
    #expect(formatted?.last != "-")
  }

  @Test("Rejects names without letters or numbers")
  func rejectsEmptyNames() {
    #expect(SessionNameFormatter.format(" -- / ") == nil)
  }
}
