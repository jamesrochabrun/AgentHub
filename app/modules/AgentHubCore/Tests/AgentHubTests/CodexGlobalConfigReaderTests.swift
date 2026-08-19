import Foundation
import Testing

@testable import AgentHubCore

@Suite("CodexGlobalConfigReader")
struct CodexGlobalConfigReaderTests {
  private func write(_ toml: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-config-\(UUID().uuidString).toml")
    try toml.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test("Reads the top-level approval_policy, ignoring comments and quoting styles")
  func readsTopLevelPolicy() throws {
    let url = try write("""
      model = "gpt-5" # comment with approval_policy = "untrusted" inside
      approvals_reviewer = "user"
      approval_policy = "never"   # global
      sandbox_mode = "danger-full-access"
      """)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(CodexGlobalConfigReader.approvalPolicy(configURL: url) == "never")

    let single = try write("approval_policy = 'on-request'\n")
    defer { try? FileManager.default.removeItem(at: single) }
    #expect(CodexGlobalConfigReader.approvalPolicy(configURL: single) == "on-request")
  }

  @Test("A policy inside a table is scoped and does not count as global")
  func tableScopedPolicyIgnored() throws {
    let url = try write("""
      model = "gpt-5"

      [profiles.safe]
      approval_policy = "untrusted"

      [projects."/tmp/x"]
      approval_policy = "never"
      """)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(CodexGlobalConfigReader.approvalPolicy(configURL: url) == nil)
    #expect(CodexGlobalConfigReader.topLevelValue(forKey: "model", in: try String(contentsOf: url, encoding: .utf8)) == "gpt-5")
  }

  @Test("Missing file or key yields nil; CODEX_HOME overrides the location")
  func missingAndCodexHome() throws {
    #expect(CodexGlobalConfigReader.approvalPolicy(configURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).toml")) == nil)
    let empty = try write("model = \"gpt-5\"\n")
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(CodexGlobalConfigReader.approvalPolicy(configURL: empty) == nil)

    let url = CodexGlobalConfigReader.defaultConfigURL(environment: ["CODEX_HOME": "/tmp/codex-home"], homeDirectory: URL(fileURLWithPath: "/Users/nobody"))
    #expect(url.path == "/tmp/codex-home/config.toml")
    let home = CodexGlobalConfigReader.defaultConfigURL(environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/nobody"))
    #expect(home.path == "/Users/nobody/.codex/config.toml")
  }
}
