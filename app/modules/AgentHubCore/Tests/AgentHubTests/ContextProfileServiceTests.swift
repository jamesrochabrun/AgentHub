import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Context profile service")
struct ContextProfileServiceTests {

  private func withService(
    _ body: (ContextProfileService, ContextProfileIndexStore) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("context-profile-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try SessionMetadataStore(
      path: root.appendingPathComponent("db.sqlite").path)
    let indexStore = ContextProfileIndexStore(
      directoryURL: root.appendingPathComponent("index", isDirectory: true))
    try await body(ContextProfileService(metadataStore: store, indexStore: indexStore), indexStore)
  }

  @Test("Profiles list project-scoped first, then personal")
  func profilesListProjectFirst() async throws {
    try await withService { service, _ in
      try await service.save(makePersonalProfile(id: "pers", name: "AAA Personal"))
      try await service.save(makeProfile(id: "proj", name: "ZZZ Project"))

      let profiles = try await service.profiles(forProjectPath: "/tmp/project")
      #expect(profiles.map(\.id) == ["proj", "pers"])
    }
  }

  @Test("Saving republishes the project's JSON index")
  func saveRepublishesIndex() async throws {
    try await withService { service, indexStore in
      try await service.save(makeProfile(id: "proj", name: "Project profile"))

      let index = try #require(indexStore.read(projectPath: "/tmp/project"))
      #expect(index.profiles.map(\.id) == ["proj"])
      #expect(index.profiles.first?.relativeFilePaths == ["Sources/App/Main.swift", "CLAUDE.md"])
    }
  }

  @Test("A personal save is merged into every project's index")
  func personalSaveMergesIntoProjectIndexes() async throws {
    try await withService { service, indexStore in
      try await service.save(makeProfile(id: "proj", name: "Project profile"))
      try await service.save(makePersonalProfile(id: "pers", name: "Personal profile"))

      let index = try #require(indexStore.read(projectPath: "/tmp/project"))
      #expect(Set(index.profiles.map(\.id)) == ["proj", "pers"])
      #expect(index.profiles.first { $0.id == "pers" }?.scope == "personal")
    }
  }

  @Test("Set-default flows through to the index and defaultProfile")
  func setDefaultFlowsThrough() async throws {
    try await withService { service, indexStore in
      try await service.save(makeProfile(id: "proj", name: "Project profile"))
      try await service.setDefault(id: "proj", forProjectPath: "/tmp/project")

      #expect(try await service.defaultProfile(forProjectPath: "/tmp/project")?.id == "proj")
      let index = try #require(indexStore.read(projectPath: "/tmp/project"))
      #expect(index.profiles.first?.isDefault == true)
    }
  }

  @Test("Deleting removes the profile from the store and the index")
  func deleteRemovesEverywhere() async throws {
    try await withService { service, indexStore in
      try await service.save(makeProfile(id: "a", name: "A"))
      try await service.save(makeProfile(id: "b", name: "B"))

      try await service.delete(id: "a", projectPath: "/tmp/project")

      #expect(try await service.profiles(forProjectPath: "/tmp/project").map(\.id) == ["b"])
      let index = try #require(indexStore.read(projectPath: "/tmp/project"))
      #expect(index.profiles.map(\.id) == ["b"])
    }
  }

  @Test("Save stamps updatedAt")
  func saveStampsUpdatedAt() async throws {
    try await withService { service, _ in
      let stale = Date(timeIntervalSince1970: 1_000)
      var profile = makeProfile(id: "proj", name: "Project profile")
      profile.updatedAt = stale

      try await service.save(profile)

      let saved = try #require(try await service.profiles(forProjectPath: "/tmp/project").first)
      #expect(saved.updatedAt > stale)
    }
  }
}
