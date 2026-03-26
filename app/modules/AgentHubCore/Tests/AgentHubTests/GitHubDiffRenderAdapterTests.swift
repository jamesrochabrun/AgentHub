//
//  GitHubDiffRenderAdapterTests.swift
//  AgentHubTests
//

import Testing

@testable import AgentHubCore

@Suite("GitHubDiffRenderAdapter")
struct GitHubDiffRenderAdapterTests {

  @Test("renders modified hunks into old and new buffers")
  func rendersModifiedHunk() {
    let patch = """
    @@ -1,3 +1,3 @@
     alpha
    -beta
    +beta updated
     gamma
    """

    let rendered = GitHubDiffRenderAdapter.renderedDiff(from: patch)

    #expect(rendered?.oldContent == "alpha\nbeta\ngamma")
    #expect(rendered?.newContent == "alpha\nbeta updated\ngamma")
  }

  @Test("renders added files with empty old content")
  func rendersAddedFile() {
    let patch = """
    @@ -0,0 +1,2 @@
    +alpha
    +beta
    """

    let rendered = GitHubDiffRenderAdapter.renderedDiff(from: patch)

    #expect(rendered?.oldContent == "")
    #expect(rendered?.newContent == "alpha\nbeta")
  }

  @Test("renders deleted files with empty new content")
  func rendersDeletedFile() {
    let patch = """
    @@ -1,2 +0,0 @@
    -alpha
    -beta
    """

    let rendered = GitHubDiffRenderAdapter.renderedDiff(from: patch)

    #expect(rendered?.oldContent == "alpha\nbeta")
    #expect(rendered?.newContent == "")
  }

  @Test("adds separators between hunks")
  func rendersMultipleHunks() {
    let patch = """
    diff --git a/File.swift b/File.swift
    index 1111111..2222222 100644
    --- a/File.swift
    +++ b/File.swift
    @@ -1,2 +1,2 @@
    -old one
    +new one
     keep one
    @@ -10,2 +10,2 @@
     keep two
    -old two
    +new two
    """

    let rendered = GitHubDiffRenderAdapter.renderedDiff(from: patch)

    #expect(rendered?.oldContent == "old one\nkeep one\n...\nkeep two\nold two")
    #expect(rendered?.newContent == "new one\nkeep one\n...\nkeep two\nnew two")
  }

  @Test("returns nil when no hunks are present")
  func returnsNilWithoutHunks() {
    let patch = "Binary files a/File.swift and b/File.swift differ"

    let rendered = GitHubDiffRenderAdapter.renderedDiff(from: patch)

    #expect(rendered == nil)
  }
}
