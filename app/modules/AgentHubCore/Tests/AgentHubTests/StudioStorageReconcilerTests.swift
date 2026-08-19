import Foundation
import Testing

@testable import AgentHubCore

@Suite("StudioStorageReconciler")
struct StudioStorageReconcilerTests {
  @Test("Orphan artifact directories are removed; known ones and empty projects are handled")
  func reconcileRemovesOrphans() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    for path in ["proj1/known/index.html", "proj1/orphan/index.html", "proj2/orphan2/index.html", "proj3/.DS_Store"] {
      let url = root.appendingPathComponent(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: url)
    }

    let report = StudioStorageReconciler(rootURL: root).reconcile(knownDirectoryNames: ["known"])

    #expect(report.removedArtifactDirectories == 2)
    #expect(report.removedEmptyProjectDirectories == 2)
    #expect(fm.fileExists(atPath: root.appendingPathComponent("proj1/known/index.html").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("proj1/orphan").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("proj2").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("proj3").path))
  }

  @Test("A missing root is a no-op")
  func missingRootIsNoop() {
    let report = StudioStorageReconciler(rootURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")).reconcile(knownDirectoryNames: [])
    #expect(report == StudioStorageReconciler.Report())
  }

  @Test("Directory size sums files")
  func directorySize() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("a"))
    try Data(repeating: 0, count: 50).write(to: root.appendingPathComponent("b"))
    #expect(StudioStorageReconciler.directorySize(at: root) == 150)
  }
}
