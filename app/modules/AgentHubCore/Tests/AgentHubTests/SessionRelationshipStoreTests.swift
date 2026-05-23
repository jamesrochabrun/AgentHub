import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session relationship store")
struct SessionRelationshipStoreTests {
  @Test("Relationship rows round-trip and are source and target scoped")
  func relationshipRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryRelationshipDatabasePath())
    let relationship = SessionRelationshipRecord(
      sourceProvider: .claude,
      sourceSessionId: "parent-1",
      targetProvider: .codex,
      targetSessionId: "child-1",
      kind: .accessoryChild,
      origin: .explicit,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )

    try await store.saveSessionRelationship(relationship)

    let fromParent = try await store.sessionRelationships(
      from: .claude,
      sessionId: "parent-1",
      kind: .accessoryChild
    )
    let toChild = try await store.sessionRelationships(
      to: .codex,
      sessionId: "child-1",
      kind: .accessoryChild
    )

    #expect(fromParent.count == 1)
    #expect(toChild.count == 1)
    #expect(fromParent.first?.targetProviderKind == .codex)
    #expect(fromParent.first?.targetSessionId == "child-1")
    #expect(fromParent.first?.relationshipOrigin == .explicit)
  }

  @Test("Deleting a relationship removes only the matching edge")
  func deleteRelationshipIsScoped() async throws {
    let store = try SessionMetadataStore(path: temporaryRelationshipDatabasePath())
    try await store.saveSessionRelationship(SessionRelationshipRecord(
      sourceProvider: .claude,
      sourceSessionId: "parent-1",
      targetProvider: .codex,
      targetSessionId: "child-1",
      kind: .accessoryChild,
      origin: .detected
    ))
    try await store.saveSessionRelationship(SessionRelationshipRecord(
      sourceProvider: .claude,
      sourceSessionId: "parent-1",
      targetProvider: .claude,
      targetSessionId: "child-2",
      kind: .accessoryChild,
      origin: .explicit
    ))

    try await store.deleteSessionRelationship(
      sourceProvider: .claude,
      sourceSessionId: "parent-1",
      targetProvider: .codex,
      targetSessionId: "child-1",
      kind: .accessoryChild
    )

    let remaining = try await store.sessionRelationships(
      from: .claude,
      sessionId: "parent-1",
      kind: .accessoryChild
    )
    #expect(remaining.map(\.targetSessionId) == ["child-2"])
  }
}

private func temporaryRelationshipDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_session_relationships_\(UUID().uuidString).sqlite")
    .path
}
