import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("StudioLibrary")
struct StudioLibraryTests {
  private func makeLibrary() throws -> (StudioLibrary, StudioPersistenceMock, URL, StudioIndexStore) {
    let root = try temporaryStudioRoot()
    let persistence = StudioPersistenceMock()
    let index = StudioIndexStore(directoryURL: root.appendingPathComponent("index"))
    let library = StudioLibrary(
      persistence: persistence,
      documents: StudioDocumentWriter(rootURL: root.appendingPathComponent("docs")),
      server: StudioServerMock(),
      index: index
    )
    return (library, persistence, root, index)
  }

  @Test("Store puts the artifact in memory first, writes the document, persists, and publishes the index")
  func storeRoundTrip() async throws {
    let (library, persistence, root, index) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    await library.store(makeStudioCanvas(id: "c1"), projectKey: "/repo", sessionId: "s1", aliasPaths: ["/repo-wt"])

    #expect(library.artifacts(forProjectKey: "/repo").map(\.id) == ["c1"])
    #expect(persistence.saved.map(\.id) == ["c1"])
    #expect(persistence.saved.first?.projectPath == "/repo")
    #expect(FileManager.default.fileExists(atPath: library.documentURL(for: makeStudioCanvas(id: "c1"), projectKey: "/repo").path))

    // Index publish is detached; poll briefly.
    var entry: StudioIndexEntry?
    for _ in 0..<50 where entry == nil {
      try await Task.sleep(for: .milliseconds(20))
      entry = index.read(projectPath: "/repo-wt")?.artifacts.first
    }
    #expect(entry?.id == "c1")
    #expect(entry?.variantNames == ["solid", "ghost"])
    #expect(entry?.documentPath?.hasSuffix("/c1/index.html") == true)
  }

  @Test("Re-filing the same id replaces in place, keeps createdAt, bumps revision")
  func refileReplacesInPlace() async throws {
    let (library, persistence, root, _) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = makeStudioCanvas(id: "c1", createdAt: Date(timeIntervalSince1970: 100))
    await library.store(first, projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    let second = makeStudioCanvas(id: "c1", title: "Primary button v2", createdAt: Date(timeIntervalSince1970: 200))
    await library.store(second, projectKey: "/repo", sessionId: "s2", aliasPaths: [])

    let stored = library.artifacts(forProjectKey: "/repo")
    #expect(stored.count == 1)
    #expect(stored[0].title == "Primary button v2")
    #expect(stored[0].createdAt == first.createdAt)
    #expect(stored[0].revision == 2)
    #expect(persistence.saved.count == 1)
    #expect(try persistence.saved.last?.decodedArtifact().revision == 2)
    #expect(persistence.saved.last?.sessionId == "s2")
  }

  @Test("Load merges persisted artifacts without dropping ones that arrived first, and is idempotent")
  func loadMerges() async throws {
    let (library, persistence, root, _) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    persistence.saved = [
      try StudioArtifactRecord(artifact: makeStudioDocument(id: "persisted"), projectPath: "/repo", sessionId: "s0")
    ]

    await library.store(makeStudioCanvas(id: "fresh"), projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    await library.load(projectKey: "/repo", aliasPaths: [])
    await library.load(projectKey: "/repo", aliasPaths: [])

    #expect(Set(library.artifacts(forProjectKey: "/repo").map(\.id)) == ["fresh", "persisted"])
    #expect(persistence.getCalls == 1)
  }

  @Test("Delete cascades to memory, disk, and persistence; deleteAll clears the project")
  func deleteCascades() async throws {
    let (library, persistence, root, _) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = makeStudioCanvas(id: "c1")
    await library.store(artifact, projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    let doc = library.documentURL(for: artifact, projectKey: "/repo")

    await library.delete(id: "c1", projectKey: "/repo", aliasPaths: [])
    #expect(library.artifacts(forProjectKey: "/repo").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: doc.path))
    #expect(persistence.deletedIds == ["c1"])

    await library.store(makeStudioCanvas(id: "c2"), projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    await library.deleteAll(projectKey: "/repo")
    #expect(library.artifacts(forProjectKey: "/repo").isEmpty)
    #expect(persistence.deletedProjects == ["/repo"])
  }

  @Test("servedURL regenerates a canvas written by an older host page")
  func servedURLRegeneratesStaleCanvas() async throws {
    let (library, _, root, _) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = makeStudioCanvas(id: "c1")
    await library.store(canvas, projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    let doc = library.documentURL(for: canvas, projectKey: "/repo")
    try Data("<html><body>stale host page</body></html>".utf8).write(to: doc)

    _ = await library.servedURL(for: canvas, projectKey: "/repo")

    let html = try String(contentsOf: doc, encoding: .utf8)
    #expect(html.contains("agenthub-studio-host"))
    #expect(html.contains("class=\"studio-artboard\" data-variant=\"solid\""))
  }

  @Test("servedURL rewrites a missing document and resolves under the server base")
  func servedURLRewritesMissingDocument() async throws {
    let (library, _, root, _) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = makeStudioDocument(id: "d1")
    await library.store(artifact, projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    let doc = library.documentURL(for: artifact, projectKey: "/repo")
    try FileManager.default.removeItem(at: doc)

    let url = try #require(await library.servedURL(for: artifact, projectKey: "/repo"))
    #expect(url.absoluteString.hasPrefix("http://127.0.0.1:1234/"))
    #expect(url.absoluteString.hasSuffix("/d1/index.html"))
    #expect(FileManager.default.fileExists(atPath: doc.path))
  }

  @Test("allProjects groups by project with bytes on disk; reconcile drops orphans")
  func allProjectsAndReconcile() async throws {
    let (library, persistence, root, _) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    await library.store(makeStudioCanvas(id: "c1"), projectKey: "/repo-a", sessionId: "s1", aliasPaths: [])
    await library.store(makeStudioDocument(id: "d1"), projectKey: "/repo-b", sessionId: "s1", aliasPaths: [])

    let projects = await library.allProjects()
    #expect(projects.map(\.projectKey) == ["/repo-a", "/repo-b"])
    #expect(projects.allSatisfy { $0.bytesOnDisk > 0 })

    // An orphan directory nobody vouches for.
    let orphan = root.appendingPathComponent("docs/zzzz/orphan", isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: orphan.appendingPathComponent("index.html"))
    persistence.deletedIds = []
    await library.reconcileStorage()
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: library.documentURL(for: makeStudioCanvas(id: "c1"), projectKey: "/repo-a").path))
  }

  @Test("Baking edits replaces only the named variants' html, bumps the revision, and republishes the payload")
  func updateVariantHTMLBakesEdits() async throws {
    let (library, persistence, root, index) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = makeStudioCanvas(id: "c1")
    await library.store(canvas, projectKey: "/repo", sessionId: "s1", aliasPaths: [])

    let stored = await library.updateVariantHTML(
      artifactId: "c1",
      htmlByVariant: ["ghost": "<button class=\"btn\" style=\"color: red;\">Buy now</button>"],
      projectKey: "/repo",
      sessionId: "s1",
      aliasPaths: []
    )

    #expect(stored?.revision == 2)
    #expect(stored?.variants.first { $0.name == "ghost" }?.html == "<button class=\"btn\" style=\"color: red;\">Buy now</button>")
    #expect(stored?.variants.first { $0.name == "ghost" }?.css == canvas.variants[1].css)
    #expect(stored?.variants.first { $0.name == "solid" } == canvas.variants[0])
    #expect(try persistence.saved.first?.decodedArtifact().variants.first { $0.name == "ghost" }?.html.contains("Buy now") == true)

    // Sidecar the CLI reads reflects the bake, and the index points at it.
    let payloadURL = StudioDocumentWriter.payloadURL(besideDocument: library.documentURL(for: canvas, projectKey: "/repo"))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(StudioArtifact.self, from: Data(contentsOf: payloadURL)).revision == 2)
    var entry: StudioIndexEntry?
    for _ in 0..<50 where entry?.revision != 2 {
      try await Task.sleep(for: .milliseconds(20))
      entry = index.read(projectPath: "/repo")?.artifacts.first
    }
    #expect(entry?.payloadPath == payloadURL.path)

    // No-op when nothing changes; unknown artifact returns nil.
    let unchanged = await library.updateVariantHTML(artifactId: "c1", htmlByVariant: [:], projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    #expect(unchanged?.revision == 2)
    #expect(await library.updateVariantHTML(artifactId: "nope", htmlByVariant: [:], projectKey: "/repo", sessionId: "s1", aliasPaths: []) == nil)
  }

  @Test("Merged keeps newest-filed first and lets incoming win")
  func mergedOrdering() {
    let a = makeStudioCanvas(id: "a", createdAt: Date(timeIntervalSince1970: 1))
    let b = makeStudioCanvas(id: "b", createdAt: Date(timeIntervalSince1970: 2))
    let a2 = makeStudioCanvas(id: "a", title: "A2", createdAt: Date(timeIntervalSince1970: 1))
    let merged = StudioLibrary.merged(existing: [b, a], incoming: [a2])
    #expect(merged.map(\.id) == ["b", "a"])
    #expect(merged[1].title == "A2")
  }
}

final class StudioPersistenceMock: StudioPersisting, @unchecked Sendable {
  var saved: [StudioArtifactRecord] = []
  var deletedIds: [String] = []
  var deletedProjects: [String] = []
  var getCalls = 0

  func saveStudioArtifact(_ record: StudioArtifactRecord) async throws {
    saved.removeAll { $0.id == record.id }
    saved.append(record)
  }

  func getStudioArtifacts(forProjectPath projectPath: String) async throws -> [StudioArtifactRecord] {
    getCalls += 1
    return saved.filter { $0.projectPath == projectPath }
  }

  func getAllStudioArtifacts() async throws -> [StudioArtifactRecord] {
    saved
  }

  func deleteStudioArtifact(id: String) async throws {
    deletedIds.append(id)
    saved.removeAll { $0.id == id }
  }

  func deleteAllStudioArtifacts(forProjectPath projectPath: String) async throws {
    deletedProjects.append(projectPath)
    saved.removeAll { $0.projectPath == projectPath }
  }
}

struct StudioServerMock: StudioStaticServing {
  func start() async throws -> URL { URL(string: "http://127.0.0.1:1234/")! }
  func stop() async {}
}
