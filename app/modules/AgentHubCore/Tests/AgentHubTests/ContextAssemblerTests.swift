import Foundation
import Testing

@testable import AgentHubCore

@Suite("Context assembler")
struct ContextAssemblerTests {

  private let assembler = ContextAssembler()

  private func loadedFile(_ path: String, _ content: String) -> ContextLoadedFile {
    ContextLoadedFile(relativePath: path, content: content)
  }

  @Test("Deterministic regardless of input order")
  func deterministicOrdering() throws {
    let files = [
      loadedFile("b/second.swift", "let b = 2"),
      loadedFile("a/first.swift", "let a = 1"),
      loadedFile("c/third.swift", "let c = 3"),
    ]
    let forward = assembler.assemble(ContextAssemblyInput(files: files, instructions: "do it"))
    let shuffled = assembler.assemble(ContextAssemblyInput(files: files.reversed(), instructions: "do it"))

    #expect(forward == shuffled)
    let aIndex = try #require(forward.block.range(of: "a/first.swift")).lowerBound
    let bIndex = try #require(forward.block.range(of: "b/second.swift")).lowerBound
    #expect(aIndex < bIndex)
  }

  @Test("Block structure contains map, files, and instructions sections")
  func blockStructure() {
    let result = assembler.assemble(ContextAssemblyInput(
      files: [loadedFile("src/main.swift", "print(\"hi\")\nprint(\"bye\")")],
      missingPaths: ["gone/away.swift"],
      instructions: "Focus on main."
    ))

    #expect(result.block.hasPrefix("<context>\n"))
    #expect(result.block.hasSuffix("\n</context>"))
    #expect(result.block.contains("<file_map>\ngone/away.swift (missing)\nsrc/main.swift (2 lines)\n</file_map>"))
    #expect(result.block.contains("<file path=\"src/main.swift\">\nprint(\"hi\")\nprint(\"bye\")\n</file>"))
    #expect(result.block.contains("<instructions>\nFocus on main.\n</instructions>"))
    #expect(result.byteCount == result.block.utf8.count)
  }

  @Test("Missing files are annotated in the map but emit no file body")
  func missingFilesAnnotated() {
    let result = assembler.assemble(ContextAssemblyInput(
      files: [],
      missingPaths: ["lost.swift"],
      instructions: ""
    ))

    #expect(result.block.contains("lost.swift (missing)"))
    #expect(!result.block.contains("<files>"))
    #expect(!result.block.contains("<instructions>"))
  }

  @Test("Empty sections are omitted")
  func emptySectionsOmitted() {
    let instructionsOnly = assembler.assemble(ContextAssemblyInput(
      files: [],
      instructions: "Just instructions."
    ))
    #expect(!instructionsOnly.block.contains("<file_map>"))
    #expect(!instructionsOnly.block.contains("<files>"))
    #expect(instructionsOnly.block.contains("<instructions>\nJust instructions.\n</instructions>"))

    let filesOnly = assembler.assemble(ContextAssemblyInput(
      files: [loadedFile("a.swift", "let a = 1")]
    ))
    #expect(filesOnly.block.contains("<file_map>"))
    #expect(filesOnly.block.contains("<files>"))
    #expect(!filesOnly.block.contains("<instructions>"))
  }

  @Test("Fully empty input produces an empty block")
  func emptyInput() {
    let result = assembler.assemble(ContextAssemblyInput(files: [], instructions: "   \n "))
    #expect(result.block.isEmpty)
    #expect(result.byteCount == 0)
  }

  @Test("Text snippets render as a titled section and appear in the map")
  func snippetsSection() {
    let result = assembler.assemble(ContextAssemblyInput(
      files: [],
      textSnippets: [
        ContextTextSnippet(id: "b", title: "Zeta", content: "second"),
        ContextTextSnippet(id: "a", title: "Alpha", content: "first"),
      ]
    ))

    #expect(result.block.contains("<snippets>\n<snippet title=\"Alpha\">\nfirst\n</snippet>\n<snippet title=\"Zeta\">\nsecond\n</snippet>\n</snippets>"))
    #expect(result.block.contains("Alpha (pasted text)"))
    #expect(result.block.contains("Zeta (pasted text)"))
  }

  @Test("Attachments are listed by path with a read-it-yourself note")
  func attachmentsSection() {
    let result = assembler.assemble(ContextAssemblyInput(
      files: [loadedFile("src/a.swift", "let a = 1")],
      attachmentPaths: ["/Users/me/books/manual.pdf"]
    ))

    #expect(result.block.contains("/Users/me/books/manual.pdf (attachment — read separately)"))
    #expect(result.block.contains("<attachments>"))
    #expect(result.block.contains("Read them with your file tools:"))
    #expect(result.block.contains("/Users/me/books/manual.pdf\n</attachments>"))
  }

  @Test("Attribute values are escaped so user text cannot break the block")
  func attributeValuesEscaped() {
    let result = assembler.assemble(ContextAssemblyInput(
      files: [loadedFile("dir/we\"ird & <odd>.swift", "let x = 1")],
      textSnippets: [
        ContextTextSnippet(id: "a", title: "spec\" mode=\"raw", content: "payload")
      ]
    ))

    #expect(result.block.contains(
      "<snippet title=\"spec&quot; mode=&quot;raw\">\npayload\n</snippet>"))
    #expect(!result.block.contains("<snippet title=\"spec\" mode=\"raw\">"))
    #expect(result.block.contains(
      "<file path=\"dir/we&quot;ird &amp; &lt;odd&gt;.swift\">\nlet x = 1\n</file>"))
  }

  @Test("Instructions are trimmed")
  func instructionsTrimmed() {
    let result = assembler.assemble(ContextAssemblyInput(
      files: [],
      instructions: "\n  Keep tests green.  \n"
    ))
    #expect(result.block.contains("<instructions>\nKeep tests green.\n</instructions>"))
  }
}
