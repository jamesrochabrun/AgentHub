import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("StudioIndexStore")
struct StudioIndexStoreTests {
  @Test("Index round-trips and is mirrored to alias paths")
  func indexRoundTripsAndMirrors() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-studio-index-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = StudioIndexStore(directoryURL: root)
    let entry = StudioIndexEntry(artifact: makeCanvas(id: "c1"), documentPath: "/tmp/studio/c1/index.html", payloadPath: "/tmp/studio/c1/artifact.json")
    let index = StudioIndex(projectPath: "/repo", updatedAt: Date(timeIntervalSince1970: 5), artifacts: [entry])

    try store.write(index, aliasPaths: ["/repo-wt-feature"])

    #expect(store.read(projectPath: "/repo") == index)
    #expect(store.read(projectPath: "/repo-wt-feature") == index)
    #expect(store.read(projectPath: "/other") == nil)
    #expect(store.read(projectPath: "/repo")?.artifacts.first?.variantNames == ["solid", "ghost"])
    #expect(store.read(projectPath: "/repo")?.artifacts.first?.payloadPath == "/tmp/studio/c1/artifact.json")

    // Older indexes without payloadPath still decode.
    let legacy = """
      {"projectPath":"/legacy","updatedAt":"2026-01-01T00:00:00Z","artifacts":[{"id":"x","kind":"canvas","title":"T","variantNames":["a"],"revision":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
      """
    try Data(legacy.utf8).write(to: store.fileURL(forProjectPath: "/legacy"))
    #expect(store.read(projectPath: "/legacy")?.artifacts.first?.payloadPath == nil)
  }

  @Test("File names are percent-encoded so separator-lookalikes never collide")
  func fileNamesArePercentEncoded() {
    #expect(StudioIndexStore.fileName(forProjectPath: "/a/b-c") != StudioIndexStore.fileName(forProjectPath: "/a-b/c"))
    #expect(!StudioIndexStore.fileName(forProjectPath: "/a/b").contains("/"))
  }
}
