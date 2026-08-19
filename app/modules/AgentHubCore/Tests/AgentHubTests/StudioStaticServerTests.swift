import Foundation
import Testing

@testable import AgentHubCore

@Suite("StudioStaticServer")
struct StudioStaticServerTests {
  @Test("Serves files under the root, resolves directories to index.html, sets no-store")
  func servesFilesUnderRoot() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("p/a", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("<h1>hi</h1>".utf8).write(to: dir.appendingPathComponent("index.html"))

    let response = StudioStaticServer.resolve(requestLine: "GET /p/a/ HTTP/1.1", rootURL: root)
    #expect(response.status == 200)
    #expect(response.contentType.hasPrefix("text/html"))
    #expect(String(decoding: response.body, as: UTF8.self) == "<h1>hi</h1>")
    #expect(String(decoding: response.data, as: UTF8.self).contains("Cache-Control: no-store"))

    #expect(StudioStaticServer.resolve(requestLine: "GET /p/a HTTP/1.1", rootURL: root).status == 200)
    #expect(StudioStaticServer.resolve(requestLine: "GET /p/a/index.html?v=2 HTTP/1.1", rootURL: root).status == 200)
    #expect(StudioStaticServer.resolve(requestLine: "GET /p/a/index.html#x HTTP/1.1", rootURL: root).status == 200)
  }

  @Test("HEAD returns headers only; other methods are rejected")
  func headAndMethods() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appendingPathComponent("f.txt"))

    let head = StudioStaticServer.resolve(requestLine: "HEAD /f.txt HTTP/1.1", rootURL: root)
    #expect(head.status == 200)
    #expect(!head.includeBody)
    #expect(String(decoding: head.data, as: UTF8.self).hasSuffix("\r\n\r\n"))

    #expect(StudioStaticServer.resolve(requestLine: "POST /f.txt HTTP/1.1", rootURL: root).status == 405)
    #expect(StudioStaticServer.resolve(requestLine: "garbage", rootURL: root).status == 400)
  }

  @Test("Paths that escape the root, dotfiles, and missing files are 404")
  func escapesAndMissingAre404() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sibling = root.deletingLastPathComponent().appendingPathComponent("secret-\(UUID().uuidString).txt")
    try Data("secret".utf8).write(to: sibling)
    defer { try? FileManager.default.removeItem(at: sibling) }
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".env"))

    for path in [
      "/../\(sibling.lastPathComponent)",
      "/%2e%2e/\(sibling.lastPathComponent)",
      "/a/../../\(sibling.lastPathComponent)",
      "/.env",
      "/missing.html",
      "relative/no/leading/slash",
    ] {
      let response = StudioStaticServer.resolve(requestLine: "GET \(path) HTTP/1.1", rootURL: root)
      #expect(response.status == 404, "\(path) → \(response.status)")
    }
    #expect(StudioStaticServer.fileURL(forRequestPath: "/../x", rootURL: root) == nil)
  }

  @Test("Content types follow the extension")
  func contentTypes() {
    #expect(StudioStaticServer.contentType(forExtension: "css").hasPrefix("text/css"))
    #expect(StudioStaticServer.contentType(forExtension: "SVG") == "image/svg+xml")
    #expect(StudioStaticServer.contentType(forExtension: "woff2") == "font/woff2")
    #expect(StudioStaticServer.contentType(forExtension: "bin") == "application/octet-stream")
  }

  @Test("Starts on loopback and serves over a real socket")
  func servesOverLoopback() async throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("p/a", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("<h1>live</h1>".utf8).write(to: dir.appendingPathComponent("index.html"))

    let server = StudioStaticServer(rootURL: root)
    let base = try await server.start()
    defer { Task { await server.stop() } }
    #expect(base.host == "127.0.0.1")
    #expect(try await server.start() == base, "start is idempotent")

    let url = try #require(URL(string: "p/a/", relativeTo: base)?.absoluteURL)
    let (data, response) = try await URLSession.shared.data(from: url)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    #expect(String(decoding: data, as: UTF8.self) == "<h1>live</h1>")

    let (_, missing) = try await URLSession.shared.data(from: URL(string: "nope.html", relativeTo: base)!.absoluteURL)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
  }
}
