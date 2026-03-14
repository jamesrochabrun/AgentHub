import Foundation
import Testing

@testable import AgentHubCore

private struct FileIndexFixture {
  let tempDir: String
  let projectPath: String
  let externalPath: String

  static func create() throws -> FileIndexFixture {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(NSTemporaryDirectory(), &resolved) != nil else {
      throw CocoaError(.fileNoSuchFile)
    }

    let tempBase = String(cString: resolved)
    let tempDir = tempBase + "/AgentHubFileIndexTests-\(UUID().uuidString)"
    let projectPath = tempDir + "/project"
    let externalPath = tempDir + "/external"

    try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: externalPath, withIntermediateDirectories: true)

    return FileIndexFixture(tempDir: tempDir, projectPath: projectPath, externalPath: externalPath)
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: tempDir)
  }

  func writeProjectFile(_ relativePath: String, content: String) throws {
    try writeFile(at: projectPath + "/" + relativePath, content: content)
  }

  func writeExternalFile(_ relativePath: String, content: String) throws {
    try writeFile(at: externalPath + "/" + relativePath, content: content)
  }

  func createProjectSymlink(_ relativePath: String, destination: String) throws {
    try FileManager.default.createSymbolicLink(
      atPath: projectPath + "/" + relativePath,
      withDestinationPath: destination
    )
  }

  private func writeFile(at path: String, content: String) throws {
    let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
  }
}

@Suite("FileIndexService privacy hardening")
struct FileIndexServicePrivacyTests {

  @Test("Rejects read access through symlinks that escape the project root")
  func rejectsSymlinkedReadOutsideProject() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeExternalFile("secret.txt", content: "top-secret")
    try fixture.createProjectSymlink("linked-external", destination: fixture.externalPath)

    let service = FileIndexService()

    do {
      _ = try await service.readFile(
        at: fixture.projectPath + "/linked-external/secret.txt",
        projectPath: fixture.projectPath
      )
      Issue.record("Expected symlinked read outside the project root to throw.")
    } catch {
      #expect(Bool(true))
    }
  }

  @Test("Rejects write access through symlinks that escape the project root")
  func rejectsSymlinkedWriteOutsideProject() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.createProjectSymlink("linked-external", destination: fixture.externalPath)

    let service = FileIndexService()

    do {
      try await service.writeFile(
        at: fixture.projectPath + "/linked-external/leak.txt",
        content: "should-not-write",
        projectPath: fixture.projectPath
      )
      Issue.record("Expected symlinked write outside the project root to throw.")
    } catch {
      #expect(Bool(true))
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.externalPath + "/leak.txt"))
  }

  @Test("Filters recent files to the actual project root instead of sibling prefix matches")
  func filtersRecentFilesToProjectBoundary() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    let insidePath = fixture.projectPath + "/Sources/App.swift"
    let siblingPath = fixture.projectPath + "-backup/Secrets/token.txt"
    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")
    try FileManager.default.createDirectory(
      atPath: URL(fileURLWithPath: siblingPath).deletingLastPathComponent().path,
      withIntermediateDirectories: true
    )
    try "token".write(toFile: siblingPath, atomically: true, encoding: .utf8)

    let service = FileIndexService()
    await service.addToRecent(insidePath)
    await service.addToRecent(siblingPath)

    let recentFiles = await service.recentFiles(in: fixture.projectPath)

    #expect(recentFiles.count == 1)
    #expect(recentFiles.first?.absolutePath == insidePath)
    #expect(recentFiles.first?.relativePath == "Sources/App.swift")
  }

  @Test("Honors directory ignore rules from .gitignore when indexing")
  func ignoresGitignoreDirectoryRules() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile(".gitignore", content: "secrets/\n")
    try fixture.writeProjectFile("secrets/token.txt", content: "hidden")
    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService()
    let hiddenResults = await service.search(query: "token", in: fixture.projectPath)
    let visibleResults = await service.search(query: "app", in: fixture.projectPath)

    #expect(hiddenResults.isEmpty)
    #expect(visibleResults.contains { $0.relativePath == "Sources/App.swift" })
  }

  @Test("Does not index secret-bearing hidden config files by default")
  func excludesSensitiveHiddenConfigs() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile(".npmrc", content: "//registry.npmjs.org/:_authToken=secret")
    try fixture.writeProjectFile(".secrets.json", content: "{\"token\":\"secret\"}")
    try fixture.writeProjectFile(".swiftlint.yml", content: "disabled_rules: []")

    let service = FileIndexService()
    let npmResults = await service.search(query: "npmrc", in: fixture.projectPath)
    let secretsResults = await service.search(query: "secrets", in: fixture.projectPath)
    let swiftlintResults = await service.search(query: "swiftlint", in: fixture.projectPath)

    #expect(npmResults.isEmpty)
    #expect(secretsResults.isEmpty)
    #expect(swiftlintResults.contains { $0.relativePath == ".swiftlint.yml" })
  }

  @Test("Loads only root nodes until a directory is expanded")
  func loadsRootNodesLazily() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")
    try fixture.writeProjectFile("Sources/Feature/Detail.swift", content: "struct Detail {}")
    try fixture.writeProjectFile("README.md", content: "# AgentHub")

    let service = FileIndexService()
    let rootNodes = await service.rootNodes(projectPath: fixture.projectPath)

    #expect(rootNodes.map(\.name) == ["Sources", "README.md"])
    #expect(rootNodes.first(where: { $0.name == "Sources" })?.children == nil)

    let sourceChildren = await service.children(
      of: fixture.projectPath + "/Sources",
      in: fixture.projectPath
    )

    #expect(sourceChildren.map(\.name) == ["Feature", "App.swift"])
    #expect(sourceChildren.first(where: { $0.name == "Feature" })?.children == nil)
  }

  @Test("Keeps tree loading and search indexing aligned with ignore rules")
  func keepsTreeAndSearchRulesInSync() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile(".gitignore", content: "Generated/\n")
    try fixture.writeProjectFile("Generated/tmp.swift", content: "let generated = true")
    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService()
    let rootNodes = await service.rootNodes(projectPath: fixture.projectPath)
    let searchResults = await service.search(query: "tmp", in: fixture.projectPath)

    #expect(rootNodes.contains { $0.name == "Sources" })
    #expect(!rootNodes.contains { $0.name == "Generated" })
    #expect(searchResults.isEmpty)
  }

  @Test("Content-only writes keep the search index warm")
  func contentOnlyWritesKeepSearchIndexReady() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService()
    let initialResults = await service.search(query: "app", in: fixture.projectPath)
    let initialStatus = await service.searchIndexStatus(projectPath: fixture.projectPath)

    try await service.writeFile(
      at: fixture.projectPath + "/Sources/App.swift",
      content: "struct App { let version = 2 }",
      projectPath: fixture.projectPath
    )

    let statusAfterWrite = await service.searchIndexStatus(projectPath: fixture.projectPath)
    let resultsAfterWrite = await service.search(query: "app", in: fixture.projectPath)

    #expect(initialResults.map(\.absolutePath) == resultsAfterWrite.map(\.absolutePath))
    #expect(initialStatus == .ready)
    #expect(statusAfterWrite == .ready)
  }

  @Test("Creating a new file invalidates cached directory listings")
  func creatingNewFileInvalidatesDirectoryCache() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService()
    let initialChildren = await service.children(
      of: fixture.projectPath + "/Sources",
      in: fixture.projectPath
    )

    try await service.writeFile(
      at: fixture.projectPath + "/Sources/NewFile.swift",
      content: "struct NewFile {}",
      projectPath: fixture.projectPath
    )

    let refreshedChildren = await service.children(
      of: fixture.projectPath + "/Sources",
      in: fixture.projectPath
    )

    #expect(initialChildren.map(\.name) == ["App.swift"])
    #expect(refreshedChildren.map(\.name) == ["App.swift", "NewFile.swift"])
  }
}
