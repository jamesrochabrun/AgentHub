import Foundation
import Testing
@testable import AgentHubCore

@Suite("ApprovalClaimStore")
struct ApprovalClaimStoreTests {

  private func makeStore() -> (ApprovalClaimStore, URL) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-claims-\(UUID().uuidString)", isDirectory: true)
    let store = ApprovalClaimStore(claimsDirectory: base)
    return (store, base)
  }

  @Test("claim creates a marker file")
  func claimCreatesMarker() async {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    await store.claim(sessionId: "abc")
    let url = dir.appendingPathComponent("abc")
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("release removes the marker file")
  func releaseRemovesMarker() async {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    await store.claim(sessionId: "abc")
    await store.release(sessionId: "abc")
    let url = dir.appendingPathComponent("abc")
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("resetAll wipes the directory then recreates it empty")
  func resetAllWipes() async {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    await store.claim(sessionId: "a")
    await store.claim(sessionId: "b")
    await store.resetAll()

    let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    #expect(contents.isEmpty)
    #expect(FileManager.default.fileExists(atPath: dir.path))
  }

  @Test("claim on empty session id is a no-op")
  func emptySessionIdIsNoop() async {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    await store.claim(sessionId: "")
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    #expect(contents.isEmpty)
  }
}
