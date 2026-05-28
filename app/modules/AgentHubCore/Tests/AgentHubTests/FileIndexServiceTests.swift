import Foundation
import Testing

import AgentHubFileSearch
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

  func writeFile(_ relativePath: String, inProjectAt path: String, content: String) throws {
    try writeFile(at: path + "/" + relativePath, content: content)
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

  func initializeGitRepository() throws {
    try runGit("init", "-b", "main")
    try runGit("config", "user.email", "test@test.com")
    try runGit("config", "user.name", "Test")
  }

  func addWorktree(branch: String) throws -> String {
    try runGit("branch", branch)
    let worktreePath = tempDir + "/" + branch.replacingOccurrences(of: "/", with: "-")
    try runGit("worktree", "add", worktreePath, branch)
    return worktreePath
  }

  @discardableResult
  func runGit(_ args: String..., at path: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: path ?? projectPath)

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw CocoaError(.fileReadUnknown, userInfo: [
        NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(error)"
      ])
    }

    return output
  }

  private func writeFile(at path: String, content: String) throws {
    let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
  }
}

private struct FakeProjectFileSearchService: ProjectFileSearchServiceProtocol {
  let results: [ProjectFileSearchResult]
  var resultsByQuery: [String: [ProjectFileSearchResult]] = [:]

  func search(query: String, in projectPath: String, limit: Int) async -> [ProjectFileSearchResult] {
    Array((resultsByQuery[query] ?? results).prefix(limit))
  }
}

private struct FakeProjectFileEnumerator: ProjectFileEnumerating {
  let kind: ProjectFileEnumerationKind?
  let result: ProjectFileEnumerationResult

  func gitProjectKind(at projectPath: String) -> ProjectFileEnumerationKind? {
    kind
  }

  func enumerateFiles(in projectPath: String) async -> ProjectFileEnumerationResult {
    result
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

  @Test("Filters Spotlight results through project ignore rules before showing Cmd+P results")
  func filtersSpotlightResultsThroughProjectIgnoreRules() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile(".gitignore", content: "secrets/\n")
    try fixture.writeProjectFile("secrets/token.swift", content: "let hidden = true")
    try fixture.writeProjectFile("Sources/token.swift", content: "let visible = true")

    let hiddenPath = fixture.projectPath + "/secrets/token.swift"
    let visiblePath = fixture.projectPath + "/Sources/token.swift"
    let service = FileIndexService(projectFileSearchService: FakeProjectFileSearchService(results: [
      ProjectFileSearchResult(
        id: hiddenPath,
        name: "token.swift",
        relativePath: "secrets/token.swift",
        absolutePath: hiddenPath,
        score: 5000
      ),
      ProjectFileSearchResult(
        id: visiblePath,
        name: "token.swift",
        relativePath: "Sources/token.swift",
        absolutePath: visiblePath,
        score: 4000
      )
    ]))

    let results = await service.search(query: "token", in: fixture.projectPath)

    #expect(results.map(\.relativePath) == ["Sources/token.swift"])
  }

  @Test("Content-only writes keep the search index warm")
  func contentOnlyWritesKeepSearchIndexReady() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService(projectFileSearchService: FakeProjectFileSearchService(results: []))
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

  @Test("Reports idle search status until the local fallback index is built")
  func reportsIdleSearchStatusBeforeFallbackIndexIsBuilt() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService(projectFileSearchService: FakeProjectFileSearchService(results: []))

    let initialStatus = await service.searchIndexStatus(projectPath: fixture.projectPath)
    await service.prepareSearchIndex(projectPath: fixture.projectPath)
    let readyStatus = await service.searchIndexStatus(projectPath: fixture.projectPath)

    #expect(initialStatus == .idle)
    #expect(readyStatus == .ready)
  }

  @Test("Search diagnostics identify local fallback results when Spotlight returns no matches")
  func searchDiagnosticsIdentifyLocalFallbackResults() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService(projectFileSearchService: FakeProjectFileSearchService(results: []))
    let diagnostics = await service.searchWithDiagnostics(query: "app", in: fixture.projectPath)

    #expect(diagnostics.source == .localIndex)
    #expect(diagnostics.spotlightCandidateCount == 0)
    #expect(diagnostics.localIndexStatusBeforeFallback == .idle)
    #expect(diagnostics.localIndexedFileCount == 1)
    #expect(diagnostics.results.map(\.relativePath) == ["Sources/App.swift"])
  }

  @Test("Git-backed index searches worktree files and excludes ignored files")
  func gitBackedIndexSearchesWorktreeFiles() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.initializeGitRepository()
    try fixture.writeProjectFile(".gitignore", content: "ignored/\n")
    try fixture.writeProjectFile("Sources/MainSearchTarget.swift", content: "struct MainSearchTarget {}")
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "initial")

    let worktreePath = try fixture.addWorktree(branch: "feature/file-index")
    try fixture.writeFile("Sources/WorktreeSearchTarget.swift", inProjectAt: worktreePath, content: "struct WorktreeSearchTarget {}")
    try fixture.runGit("add", "Sources/WorktreeSearchTarget.swift", at: worktreePath)
    try fixture.runGit("commit", "-m", "worktree file", at: worktreePath)
    try fixture.writeFile("Sources/UntrackedSearchTarget.swift", inProjectAt: worktreePath, content: "struct UntrackedSearchTarget {}")
    try fixture.writeFile("ignored/IgnoredSearchTarget.swift", inProjectAt: worktreePath, content: "struct IgnoredSearchTarget {}")

    let service = FileIndexService(projectFileSearchService: FakeProjectFileSearchService(results: []))
    let diagnostics = await service.searchWithDiagnostics(query: "searchtarget", in: worktreePath)
    let relativePaths = Set(diagnostics.results.map(\.relativePath))

    #expect(diagnostics.source == .localIndex)
    #expect(diagnostics.spotlightCandidateCount == 0)
    #expect(relativePaths.contains("Sources/MainSearchTarget.swift"))
    #expect(relativePaths.contains("Sources/WorktreeSearchTarget.swift"))
    #expect(relativePaths.contains("Sources/UntrackedSearchTarget.swift"))
    #expect(!relativePaths.contains("ignored/IgnoredSearchTarget.swift"))
  }

  @Test("Worktree search uses local Git index before Spotlight")
  func worktreeSearchSkipsSpotlight() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("LocalOnly.swift", content: "struct LocalOnly {}")
    try fixture.writeProjectFile("SpotlightOnly.swift", content: "struct SpotlightOnly {}")

    let service = FileIndexService(
      projectFileSearchService: FakeProjectFileSearchService(results: [
        ProjectFileSearchResult(
          id: fixture.projectPath + "/SpotlightOnly.swift",
          name: "SpotlightOnly.swift",
          relativePath: "SpotlightOnly.swift",
          absolutePath: fixture.projectPath + "/SpotlightOnly.swift",
          score: 5000
        )
      ]),
      projectFileEnumerator: FakeProjectFileEnumerator(
        kind: .gitWorktree,
        result: .files([
          ProjectFileEnumeratorFile(relativePath: "LocalOnly.swift")
        ], kind: .gitWorktree)
      )
    )

    let diagnostics = await service.searchWithDiagnostics(query: "only", in: fixture.projectPath)

    #expect(diagnostics.source == .localIndex)
    #expect(diagnostics.spotlightCandidateCount == 0)
    #expect(diagnostics.results.map(\.relativePath) == ["LocalOnly.swift"])
  }

  @Test("Non-Git folders fall back to recursive indexing")
  func nonGitFoldersUseRecursiveIndex() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService(
      projectFileSearchService: FakeProjectFileSearchService(results: []),
      projectFileEnumerator: FakeProjectFileEnumerator(
        kind: nil,
        result: .notGitProject
      )
    )

    let diagnostics = await service.searchWithDiagnostics(query: "app", in: fixture.projectPath)

    #expect(diagnostics.source == .localIndex)
    #expect(diagnostics.localIndexedFileCount == 1)
    #expect(diagnostics.results.map(\.relativePath) == ["Sources/App.swift"])
  }

  @Test("Git enumeration failure stays bounded instead of recursively scanning")
  func gitEnumerationFailureReturnsEmptyLocalIndex() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")

    let service = FileIndexService(
      projectFileSearchService: FakeProjectFileSearchService(results: []),
      projectFileEnumerator: FakeProjectFileEnumerator(
        kind: .gitRepository,
        result: .failed
      )
    )

    let diagnostics = await service.searchWithDiagnostics(query: "app", in: fixture.projectPath)

    #expect(diagnostics.source == .localIndex)
    #expect(diagnostics.localIndexedFileCount == 0)
    #expect(diagnostics.results.isEmpty)
  }

  @Test("Filters hidden ancestor directories from search results")
  func filtersHiddenAncestorDirectoriesFromSearchResults() async throws {
    let fixture = try FileIndexFixture.create()
    defer { fixture.cleanup() }

    let claudePath = fixture.projectPath + "/.claude/settings.local.json"
    let githubPath = fixture.projectPath + "/.github/workflows/build.yml"
    try fixture.writeProjectFile(".claude/settings.local.json", content: "{}")
    try fixture.writeProjectFile(".github/workflows/build.yml", content: "name: build")

    let hiddenService = FileIndexService(projectFileSearchService: FakeProjectFileSearchService(results: [
      ProjectFileSearchResult(
        id: claudePath,
        name: "settings.local.json",
        relativePath: ".claude/settings.local.json",
        absolutePath: claudePath,
        score: 5000
      )
    ]))
    let allowedService = FileIndexService(projectFileSearchService: FakeProjectFileSearchService(results: [
      ProjectFileSearchResult(
        id: githubPath,
        name: "build.yml",
        relativePath: ".github/workflows/build.yml",
        absolutePath: githubPath,
        score: 5000
      )
    ]))

    let hiddenResults = await hiddenService.search(query: "settings", in: fixture.projectPath)
    let allowedResults = await allowedService.search(query: "build", in: fixture.projectPath)

    #expect(hiddenResults.isEmpty)
    #expect(allowedResults.map(\.relativePath) == [".github/workflows/build.yml"])
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
