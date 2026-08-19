import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("StudioArtifactQueue")
struct StudioArtifactQueueTests {
  @Test("Enqueue writes the artifact and it reads back intact")
  func enqueueRoundTrips() throws {
    let directory = try temporaryStudioDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = StudioArtifactQueue(directoryURL: directory)
    let artifact = makeCanvas(id: "canvas-1")
    let queued = try queue.enqueue(artifact)

    #expect(FileManager.default.fileExists(atPath: queued.fileURL.path))
    #expect(try queue.pendingArtifacts().map(\.artifact) == [artifact])
  }

  @Test("Pending artifacts are ordered oldest first")
  func pendingOrderedOldestFirst() throws {
    let directory = try temporaryStudioDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = StudioArtifactQueue(directoryURL: directory)
    try queue.enqueue(makeCanvas(id: "newer", createdAt: Date(timeIntervalSince1970: 9_000)))
    try queue.enqueue(makeCanvas(id: "older", createdAt: Date(timeIntervalSince1970: 1_000)))

    #expect(try queue.pendingArtifacts().map(\.artifact.id) == ["older", "newer"])
  }

  @Test("Temp files and failed files are ignored; remove and markFailed work")
  func removeAndMarkFailed() throws {
    let directory = try temporaryStudioDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = StudioArtifactQueue(directoryURL: directory)
    let a = try queue.enqueue(makeCanvas(id: "a"))
    let b = try queue.enqueue(makeCanvas(id: "b"))
    try Data("garbage".utf8).write(to: directory.appendingPathComponent(".c.tmp"))

    try queue.remove(a)
    try queue.markFailed(b)

    #expect(try queue.pendingArtifacts().isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.failed").path))
  }

  @Test("Re-filing preserves createdAt, bumps revision, stamps updatedAt")
  func replacingKeepsIdentity() {
    let first = makeCanvas(id: "x", createdAt: Date(timeIntervalSince1970: 100))
    let second = makeCanvas(id: "x", createdAt: Date(timeIntervalSince1970: 200))
    let merged = second.replacing(first)
    #expect(merged.createdAt == first.createdAt)
    #expect(merged.updatedAt == second.createdAt)
    #expect(merged.revision == 2)
    #expect(merged.displayDate == second.createdAt)
  }
}

func temporaryStudioDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-studio-tests-\(UUID().uuidString)", isDirectory: true)
  let directory = root.appendingPathComponent("studio-records", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

func makeCanvas(id: String, createdAt: Date = Date(timeIntervalSince1970: 1_000)) -> StudioArtifact {
  StudioArtifact(
    id: id,
    kind: .canvas,
    createdAt: createdAt,
    title: "Primary button",
    sourcePath: "src/Button.tsx",
    variants: [
      StudioVariant(name: "solid", html: "<button>Go</button>", css: "button { color: red; }", notes: "default"),
      StudioVariant(name: "ghost", html: "<button>Go</button>", css: "button { color: blue; }", width: 320),
    ],
    warnings: ["ghost: dropped a script"],
    sourceProvider: .claude,
    sourceSessionId: "session-1",
    sourceProjectPath: "/tmp/project",
    sourceProcessId: 42
  )
}
