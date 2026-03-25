import Foundation
import Testing

@testable import AgentHubCore

private struct WebPreviewFixture {
  let root: URL

  static func create() throws -> WebPreviewFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebPreviewResolverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return WebPreviewFixture(root: root)
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

private func normalizedPath(_ path: String) -> String {
  URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

@Suite("WebPreviewResolver")
struct WebPreviewResolverTests {

  @Test("Static preview prefers root index.html even when normal resolution prefers dev server")
  func staticPreviewPrefersRootIndexHTMLForFrameworkProjects() async throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write(
      "package.json",
      content: #"{"dependencies":{"next":"15.0.0"}}"#
    )
    try fixture.write("index.html", content: "<html><body>fallback</body></html>")

    let normalResolution = await WebPreviewResolver.resolve(projectPath: fixture.root.path)
    let staticResolution = await WebPreviewResolver.resolveStaticPreview(projectPath: fixture.root.path)

    #expect(normalResolution == .devServer(projectPath: fixture.root.path))
    guard case .directFile(let filePath, let projectPath) = staticResolution else {
      Issue.record("Expected a direct-file static preview resolution.")
      return
    }
    #expect(normalizedPath(filePath) == normalizedPath(fixture.root.appendingPathComponent("index.html").path))
    #expect(projectPath == fixture.root.path)
  }

  @Test("Static preview falls back to discovered HTML when index is missing")
  func staticPreviewFallsBackToDiscoveredHTMLWhenIndexMissing() async throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("public/hello.html", content: "<html><body>hello</body></html>")

    let staticResolution = await WebPreviewResolver.resolveStaticPreview(projectPath: fixture.root.path)

    guard case .directFile(let filePath, let projectPath) = staticResolution else {
      Issue.record("Expected a direct-file static preview resolution.")
      return
    }
    #expect(normalizedPath(filePath) == normalizedPath(fixture.root.appendingPathComponent("public/hello.html").path))
    #expect(projectPath == fixture.root.path)
  }

  @Test("Static preview returns no content when no HTML files exist")
  func staticPreviewReturnsNoContentWhenNoHTMLFilesExist() async throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("README.md", content: "# AgentHub")

    let staticResolution = await WebPreviewResolver.resolveStaticPreview(projectPath: fixture.root.path)

    #expect(staticResolution == .noContent(reason: "No web-renderable files found in this project."))
  }
}

// MARK: - hasAnyHTMLFile

@Suite("WebPreviewResolver.hasAnyHTMLFile")
struct WebPreviewResolverHasAnyHTMLFileTests {

  @Test("Returns true for root index.html")
  func rootIndexHTML() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == true)
  }

  @Test("Returns true for public/index.html")
  func publicIndexHTML() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("public/index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == true)
  }

  @Test("Returns true for static/index.html")
  func staticIndexHTML() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("static/index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == true)
  }

  @Test("Returns true for dist/index.html")
  func distIndexHTML() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("dist/index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == true)
  }

  @Test("Returns true for build/index.html")
  func buildIndexHTML() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("build/index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == true)
  }

  @Test("Returns true for www/index.html")
  func wwwIndexHTML() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("www/index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == true)
  }

  @Test("Returns true for src/index.html")
  func srcIndexHTML() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("src/index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == true)
  }

  @Test("Returns false when no HTML files exist")
  func noHTMLFiles() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("README.md", content: "# Hello")
    try fixture.write("src/app.js", content: "console.log('hi')")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == false)
  }

  @Test("Returns false for HTML in unchecked subdirectory")
  func htmlInDeepSubdirectory() throws {
    let fixture = try WebPreviewFixture.create()
    defer { fixture.cleanup() }

    try fixture.write("docs/guide/index.html", content: "<html></html>")

    #expect(WebPreviewResolver.hasAnyHTMLFile(at: fixture.root.path) == false)
  }
}
