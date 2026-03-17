import Foundation
import Testing

@testable import AgentHubCore

@Suite("PendingChangesPreviewService")
struct PendingChangesPreviewServiceTests {

  @Test("Generates edit preview for an existing file")
  func generatesEditPreviewForExistingFile() async throws {
    let fixture = try TemporaryPreviewFixture()
    defer { fixture.cleanup() }

    let fileURL = fixture.directoryURL.appendingPathComponent("Example.swift")
    try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let preview = try await PendingChangesPreviewService.generatePreview(
      for: CodeChangeInput(
        toolType: .edit,
        filePath: fileURL.path,
        oldString: "let value = 1",
        newString: "let value = 2"
      )
    )

    #expect(preview.currentContent == "let value = 1\n")
    #expect(preview.previewContent == "let value = 2\n")
    #expect(preview.isNewFile == false)
  }

  @Test("Generates write preview for a new file")
  func generatesWritePreviewForNewFile() async throws {
    let fixture = try TemporaryPreviewFixture()
    defer { fixture.cleanup() }

    let fileURL = fixture.directoryURL.appendingPathComponent("NewFile.swift")

    let preview = try await PendingChangesPreviewService.generatePreview(
      for: CodeChangeInput(
        toolType: .write,
        filePath: fileURL.path,
        newString: "struct NewFile {}\n"
      )
    )

    #expect(preview.currentContent.isEmpty)
    #expect(preview.previewContent == "struct NewFile {}\n")
    #expect(preview.isNewFile)
  }
}

private struct TemporaryPreviewFixture {
  let directoryURL: URL

  init() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    self.directoryURL = url
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
