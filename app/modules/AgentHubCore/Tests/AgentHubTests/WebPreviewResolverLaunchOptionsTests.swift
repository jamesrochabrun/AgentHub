import Foundation
import Testing

@testable import AgentHubCore

private struct LaunchOptionsFixture {
  let root: URL

  static func create() throws -> LaunchOptionsFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebPreviewResolverLaunchOptionsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return LaunchOptionsFixture(root: root)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ relativePath: String, content: String) throws {
    let fileURL = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
  }
}

@Suite("WebPreviewResolver.resolveLaunchOptions")
struct WebPreviewResolverLaunchOptionsTests {

  @Test("Includes a static fallback when a root index.html is present")
  func includesStaticFallbackWithRootIndexHTML() async throws {
    let fixture = try LaunchOptionsFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("index.html", content: "<html><body>fallback</body></html>")
    let url = URL(string: "http://localhost:3000")!

    let resolution = await WebPreviewResolver.resolveLaunchOptions(
      projectPath: fixture.root.path,
      unreachableURL: url
    )

    guard case .launchOptions(let options, let unreachableURL) = resolution else {
      Issue.record("Expected a launchOptions resolution.")
      return
    }
    #expect(options.hasStaticFallback == true)
    #expect(options.canAskAgent == true)
    #expect(unreachableURL == url)
  }

  @Test("Has no static fallback when no HTML files exist")
  func noStaticFallbackWhenProjectHasNoHTML() async throws {
    let fixture = try LaunchOptionsFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("README.md", content: "# No HTML here")

    let resolution = await WebPreviewResolver.resolveLaunchOptions(
      projectPath: fixture.root.path,
      unreachableURL: URL(string: "http://localhost:8000")!
    )

    guard case .launchOptions(let options, _) = resolution else {
      Issue.record("Expected a launchOptions resolution.")
      return
    }
    #expect(options.hasStaticFallback == false)
    #expect(options.canAskAgent == true)
  }

  @Test("canAskAgent can be suppressed for contexts without a live session")
  func canAskAgentCanBeSuppressed() async throws {
    let fixture = try LaunchOptionsFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("README.md", content: "# Nothing")

    let resolution = await WebPreviewResolver.resolveLaunchOptions(
      projectPath: fixture.root.path,
      unreachableURL: nil,
      canAskAgent: false
    )

    guard case .launchOptions(let options, let unreachableURL) = resolution else {
      Issue.record("Expected a launchOptions resolution.")
      return
    }
    #expect(options.canAskAgent == false)
    #expect(unreachableURL == nil)
  }
}
