import Testing

@testable import AgentHubCore

@Suite("GitDiffTreeBuilder")
struct GitDiffTreeBuilderTests {

  @Test("builds stable ids across rebuilds")
  func buildsStableIdsAcrossRebuilds() {
    let files = [
      entry("Sources/App/View.swift"),
      entry("Sources/App/Model.swift"),
      entry("Tests/AppTests/ViewTests.swift"),
    ]

    let first = GitDiffTreeBuilder.build(from: files)
    let second = GitDiffTreeBuilder.build(from: files)

    #expect(flattenIds(first.nodes) == flattenIds(second.nodes))
  }

  @Test("strips common directory prefix")
  func stripsCommonPrefix() throws {
    let result = GitDiffTreeBuilder.build(from: [
      entry("Sources/App/View.swift"),
      entry("Sources/App/Model.swift"),
    ])

    #expect(result.commonPrefix == "Sources/App")
    #expect(result.nodes.map(\.name) == ["Model.swift", "View.swift"])
  }

  @Test("sorts folders before files deterministically")
  func sortsFoldersBeforeFiles() {
    let result = GitDiffTreeBuilder.build(from: [
      entry("z-file.swift"),
      entry("A/child.swift"),
      entry("b-file.swift"),
    ])

    #expect(result.nodes.map(\.name) == ["A", "b-file.swift", "z-file.swift"])
    #expect(result.nodes.first?.children.map(\.name) == ["child.swift"])
  }

  private func entry(_ relativePath: String) -> GitDiffFileEntry {
    GitDiffFileEntry(
      filePath: "/tmp/repo/\(relativePath)",
      relativePath: relativePath,
      additions: 1,
      deletions: 0
    )
  }

  private func flattenIds(_ nodes: [GitDiffTreeNode]) -> [String] {
    nodes.flatMap { node in
      [node.id] + flattenIds(node.children)
    }
  }
}
