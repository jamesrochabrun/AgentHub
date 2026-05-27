import Foundation
import Testing

@testable import AgentHubFileSearch

private struct SpotlightSearchFixture {
  let tempDir: String
  let projectPath: String
  let externalPath: String

  static func create() throws -> SpotlightSearchFixture {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(NSTemporaryDirectory(), &resolved) != nil else {
      throw CocoaError(.fileNoSuchFile)
    }

    let tempBase = String(cString: resolved)
    let tempDir = tempBase + "/AgentHubSpotlightSearchTests-\(UUID().uuidString)"
    let projectPath = tempDir + "/project"
    let externalPath = tempDir + "/external"

    try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: externalPath, withIntermediateDirectories: true)

    return SpotlightSearchFixture(tempDir: tempDir, projectPath: projectPath, externalPath: externalPath)
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: tempDir)
  }

  func writeProjectFile(_ relativePath: String, content: String = "") throws -> String {
    try writeFile(at: projectPath + "/" + relativePath, content: content)
    return projectPath + "/" + relativePath
  }

  func writeExternalFile(_ relativePath: String, content: String = "") throws -> String {
    try writeFile(at: externalPath + "/" + relativePath, content: content)
    return externalPath + "/" + relativePath
  }

  func createProjectDirectory(_ relativePath: String) throws -> String {
    let path = projectPath + "/" + relativePath
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func writeFile(at path: String, content: String) throws {
    let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
  }
}

private struct FakeSpotlightMetadataClient: SpotlightMetadataQuerying {
  let paths: [String]

  func searchFilePaths(matching query: String, in projectPath: String, limit: Int) -> [String] {
    Array(paths.prefix(limit))
  }
}

@Suite("SpotlightProjectFileSearchService")
struct SpotlightProjectFileSearchServiceTests {
  @Test("Builds the Spotlight metadata query across filename attributes")
  func buildsQueryExpression() {
    let expression = SpotlightQueryBuilder.expression(for: "App")

    #expect(expression == """
    (kMDItemFSName == "*App*"cd || kMDItemDisplayName == "*App*"cd)
    """)
    #expect(expression?.contains("kMDItemPath") == false)
    #expect(SpotlightQueryBuilder.expression(for: "   ") == nil)
  }

  @Test("Uses the filename component for path-like queries")
  func pathLikeQueryExpressionUsesFilenameComponent() {
    let expression = SpotlightQueryBuilder.expression(for: "Sources/App")

    #expect(expression == """
    (kMDItemFSName == "*App*"cd || kMDItemDisplayName == "*App*"cd)
    """)
  }

  @Test("Escapes quoted query literals before building the metadata query")
  func escapesQueryExpression() {
    let expression = SpotlightQueryBuilder.expression(for: #"a"b\c"#)

    #expect(expression?.contains(#"*a\"b\\c*"#) == true)
  }

  @Test("Ranks Spotlight paths and filters directories and paths outside the project")
  func ranksAndFiltersMetadataPaths() async throws {
    let fixture = try SpotlightSearchFixture.create()
    defer { fixture.cleanup() }

    let appPath = try fixture.writeProjectFile("Sources/App.swift", content: "struct App {}")
    let notesPath = try fixture.writeProjectFile("docs/app-notes.md", content: "# Notes")
    let readmePath = try fixture.writeProjectFile("README.md", content: "# Project")
    let directoryPath = try fixture.createProjectDirectory("AppDirectory")
    let externalPath = try fixture.writeExternalFile("AppSecret.swift", content: "let token = true")

    let service = SpotlightProjectFileSearchService(
      metadataClient: FakeSpotlightMetadataClient(paths: [
        readmePath,
        externalPath,
        directoryPath,
        notesPath,
        appPath,
        appPath
      ]),
      fileChecker: FileManagerSearchableFileChecker()
    )

    let results = await service.search(query: "app", in: fixture.projectPath, limit: 10)

    #expect(results.map(\.relativePath) == [
      "Sources/App.swift",
      "docs/app-notes.md"
    ])
    #expect(results.allSatisfy { $0.absolutePath.hasPrefix(fixture.projectPath + "/") })
  }
}
