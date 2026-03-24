import Canvas
import Foundation
import Testing

@testable import AgentHubCore

private struct SourceResolverFixture {
  let root: URL

  static func create() throws -> SourceResolverFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebPreviewSourceResolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SourceResolverFixture(root: root)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ relativePath: String, content: String) throws -> String {
    let fileURL = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
    return normalizedPath(fileURL.path)
  }
}

private func normalizedPath(_ path: String) -> String {
  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

private func makeInspectedElement(
  tagName: String,
  selector: String,
  elementID: String = "",
  className: String = "",
  textContent: String = ""
) -> ElementInspectorData {
  ElementInspectorData(
    tagName: tagName,
    elementId: elementID,
    className: className,
    textContent: textContent,
    outerHTML: "",
    cssSelector: selector,
    computedStyles: [:],
    boundingRect: .zero
  )
}

@Suite("WebPreviewSourceResolver")
struct WebPreviewSourceResolverSourceMappingTests {

  @Test("Uses the preview file when it contains a strong unique match")
  func resolvesPreviewFileWithHighConfidence() async throws {
    let fixture = try SourceResolverFixture.create()
    defer { fixture.cleanup() }

    let indexPath = try fixture.write(
      "index.html",
      content: """
      <html>
        <body>
          <button id="launch" class="cta">Launch now</button>
        </body>
      </html>
      """
    )

    let resolver = WebPreviewSourceResolver(fileService: ProjectFileService.shared)
    let resolution = await resolver.resolveSource(
      for: makeInspectedElement(
        tagName: "BUTTON",
        selector: "button.cta",
        elementID: "launch",
        className: "cta",
        textContent: "Launch now"
      ),
      projectPath: fixture.root.path,
      previewFilePath: indexPath,
      recentActivities: []
    )

    #expect(resolution.primaryFilePath == indexPath)
    #expect(resolution.confidence == .high)
    #expect(resolution.editableCapabilities == [.code])
    #expect(resolution.candidateFilePaths.first == indexPath)
    #expect(resolution.matchedStylesheetPath == nil)
    #expect(!resolution.allowsInlineStyleEditing)
  }

  @Test("Prefers a matched stylesheet over the preview HTML for style editing")
  func prefersMatchedStylesheetOverPreviewHTML() async throws {
    let fixture = try SourceResolverFixture.create()
    defer { fixture.cleanup() }

    let indexPath = try fixture.write(
      "index.html",
      content: """
      <html>
        <body>
          <button class="cta">Launch now</button>
        </body>
      </html>
      """
    )
    let stylesheetPath = try fixture.write(
      "styles/site.css",
      content: """
      .cta {
        color: #ffffff;
        line-height: 28px;
      }
      """
    )

    let resolver = WebPreviewSourceResolver(fileService: ProjectFileService.shared)
    let resolution = await resolver.resolveSource(
      for: makeInspectedElement(
        tagName: "BUTTON",
        selector: ".cta",
        className: "cta",
        textContent: "Launch now"
      ),
      projectPath: fixture.root.path,
      previewFilePath: indexPath,
      recentActivities: []
    )

    #expect(resolution.primaryFilePath == stylesheetPath)
    #expect(resolution.matchedStylesheetPath == stylesheetPath)
    #expect(resolution.allowsInlineStyleEditing)
    #expect(resolution.editableCapabilities.contains(.lineHeight))
  }

  @Test("Prefers recently edited stylesheet files for styleable matches")
  func resolvesRecentStylesheetForStyleEditing() async throws {
    let fixture = try SourceResolverFixture.create()
    defer { fixture.cleanup() }

    let stylesheetPath = try fixture.write(
      "styles/site.css",
      content: """
      .cta {
        color: #ffffff;
        padding: 12px;
      }
      """
    )

    let activity = ActivityEntry(
      timestamp: Date(),
      type: .toolUse(name: "Edit"),
      description: "Updated CTA styles",
      toolInput: CodeChangeInput(toolType: .edit, filePath: stylesheetPath)
    )

    let resolver = WebPreviewSourceResolver(fileService: ProjectFileService.shared)
    let resolution = await resolver.resolveSource(
      for: makeInspectedElement(
        tagName: "BUTTON",
        selector: ".cta",
        className: "cta"
      ),
      projectPath: fixture.root.path,
      previewFilePath: nil,
      recentActivities: [activity]
    )

    #expect(resolution.primaryFilePath == stylesheetPath)
    #expect(resolution.confidence == .high)
    #expect(resolution.editableCapabilities.contains(.textColor))
    #expect(resolution.editableCapabilities.contains(.padding))
    #expect(resolution.matchedStylesheetPath == stylesheetPath)
    #expect(resolution.allowsInlineStyleEditing)
  }

  @Test("Leaves ambiguous matches in low confidence fallback mode")
  func returnsLowConfidenceForAmbiguousMatches() async throws {
    let fixture = try SourceResolverFixture.create()
    defer { fixture.cleanup() }

    let firstPath = try fixture.write("pages/a.html", content: "<button>Launch</button>")
    let secondPath = try fixture.write("pages/b.html", content: "<button>Launch</button>")

    let resolver = WebPreviewSourceResolver(fileService: ProjectFileService.shared)
    let resolution = await resolver.resolveSource(
      for: makeInspectedElement(
        tagName: "BUTTON",
        selector: "button",
        textContent: "Launch"
      ),
      projectPath: fixture.root.path,
      previewFilePath: nil,
      recentActivities: []
    )

    #expect(resolution.confidence == .low)
    #expect(Set(resolution.candidateFilePaths) == Set([firstPath, secondPath]))
    #expect(resolution.editableCapabilities == [.code])
    #expect(!resolution.allowsInlineStyleEditing)
  }
}
