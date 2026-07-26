import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SessionNamingContextProvider")
struct SessionNamingContextProviderTests {
  @Test("Reads worktree and branch without invoking git")
  func readsWorktreeAndBranch() throws {
    let fixture = try SessionNamingContextFixture()
    defer { fixture.remove() }
    try fixture.makeWorktree(named: "fast-session", branch: "feature/quick-names")

    let context = fixture.provider.context(
      provider: .codex,
      projectPath: fixture.worktreeURL.appendingPathComponent("app/module").path,
      sessionId: nil
    )

    #expect(context.worktreeName == "fast-session")
    #expect(context.branchName == "feature/quick-names")
    #expect(context.claudeSessionName == nil)
  }

  @Test("Reads Claude session name from the requested session")
  func readsClaudeSessionNameById() throws {
    let fixture = try SessionNamingContextFixture()
    defer { fixture.remove() }
    try fixture.makeWorktree(named: "fast-session", branch: "feature/quick-names")
    try fixture.writeClaudeSession(id: "session-1", slug: "swift-dancing-orbit")

    let context = fixture.provider.context(
      provider: .claude,
      projectPath: fixture.worktreeURL.path,
      sessionId: "session-1"
    )

    #expect(context.claudeSessionName == "swift-dancing-orbit")
  }

  @Test("Uses newest Claude session when a new session has no ID")
  func readsNewestClaudeSessionName() throws {
    let fixture = try SessionNamingContextFixture()
    defer { fixture.remove() }
    try fixture.makeWorktree(named: "fast-session", branch: "main")
    let oldURL = try fixture.writeClaudeSession(id: "old", slug: "older-name")
    let newURL = try fixture.writeClaudeSession(id: "new", slug: "current-name")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)],
      ofItemAtPath: oldURL.path
    )
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2_000)],
      ofItemAtPath: newURL.path
    )

    let context = fixture.provider.context(
      provider: .claude,
      projectPath: fixture.worktreeURL.path,
      sessionId: nil
    )

    #expect(context.claudeSessionName == "current-name")
  }
}

private final class SessionNamingContextFixture {
  let rootURL: URL
  let homeURL: URL
  private(set) var worktreeURL: URL

  var provider: SessionNamingContextProvider {
    SessionNamingContextProvider(homeDirectory: homeURL)
  }

  init() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-session-naming-context-\(UUID().uuidString)")
    homeURL = rootURL.appendingPathComponent("home")
    worktreeURL = rootURL.appendingPathComponent("unset")
    try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
  }

  func makeWorktree(named name: String, branch: String) throws {
    worktreeURL = rootURL.appendingPathComponent(name)
    let gitURL = worktreeURL.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
    try "ref: refs/heads/\(branch)\n".write(
      to: gitURL.appendingPathComponent("HEAD"),
      atomically: true,
      encoding: .utf8
    )
  }

  @discardableResult
  func writeClaudeSession(id: String, slug: String) throws -> URL {
    let encodedPath = worktreeURL.path
      .replacing("/", with: "-")
      .replacing(".", with: "-")
      .replacing("_", with: "-")
    let directory = homeURL
      .appendingPathComponent(".claude/projects")
      .appendingPathComponent(encodedPath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(id).jsonl")
    try """
    {"type":"user","sessionId":"\(id)","slug":"\(slug)"}

    """.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
