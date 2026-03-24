import Canvas
import Foundation
import Testing

@testable import AgentHubCore

private actor MockWebPreviewSourceResolver: WebPreviewSourceResolverProtocol {
  private var queuedResolutions: [WebPreviewSourceResolution]

  init(queuedResolutions: [WebPreviewSourceResolution]) {
    self.queuedResolutions = queuedResolutions
  }

  func resolveSource(
    for element: ElementInspectorData,
    projectPath: String,
    previewFilePath: String?,
    recentActivities: [ActivityEntry]
  ) async -> WebPreviewSourceResolution {
    guard !queuedResolutions.isEmpty else {
      return WebPreviewSourceResolution(
        primaryFilePath: nil,
        candidateFilePaths: [],
        confidence: .low,
        matchedRanges: [:],
        editableCapabilities: [.code],
        matchedSelector: nil,
        matchedStylesheetPath: nil,
        allowsInlineStyleEditing: false,
        matchedText: nil
      )
    }

    return queuedResolutions.removeFirst()
  }
}

private actor MockProjectFileService: ProjectFileServiceProtocol {
  struct WriteCall: Equatable, Sendable {
    let path: String
    let content: String
  }

  enum MockError: Error, Sendable {
    case missingFile(String)
  }

  private var files: [String: String]
  private var writes: [WriteCall] = []

  init(files: [String: String]) {
    self.files = files
  }

  func readFile(at path: String, projectPath: String) async throws -> String {
    guard let content = files[path] else {
      throw MockError.missingFile(path)
    }
    return content
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    files[path] = content
    writes.append(WriteCall(path: path, content: content))
  }

  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String] {
    files.keys.sorted()
  }

  func recordedWrites() async -> [WriteCall] {
    writes
  }
}

private func makeResolution(
  primaryFilePath: String?,
  candidateFilePaths: [String],
  confidence: WebPreviewSourceResolutionConfidence,
  matchedSelector: String? = nil,
  matchedStylesheetPath: String? = nil,
  allowsInlineStyleEditing: Bool = false
) -> WebPreviewSourceResolution {
  var capabilities: Set<WebPreviewEditableCapability> = [.code]
  if allowsInlineStyleEditing {
    for property in WebPreviewStyleProperty.allCases {
      capabilities.insert(property.capability)
    }
  }

  return WebPreviewSourceResolution(
    primaryFilePath: primaryFilePath,
    candidateFilePaths: candidateFilePaths,
    confidence: confidence,
    matchedRanges: [:],
    editableCapabilities: capabilities,
    matchedSelector: matchedSelector,
    matchedStylesheetPath: matchedStylesheetPath,
    allowsInlineStyleEditing: allowsInlineStyleEditing,
    matchedText: "Launch"
  )
}

private func makeElement(
  tagName: String = "BUTTON",
  selector: String = ".cta",
  className: String = "cta",
  textContent: String = "Launch",
  computedStyles: [String: String] = [:]
) -> ElementInspectorData {
  ElementInspectorData(
    tagName: tagName,
    elementId: "",
    className: className,
    textContent: textContent,
    outerHTML: "",
    cssSelector: selector,
    computedStyles: computedStyles,
    boundingRect: .zero
  )
}

@Suite("WebPreviewInspectorViewModel")
struct WebPreviewInspectorViewModelTests {

  @Test("Rapid edits are collapsed into a single debounced write")
  func collapsesRapidEditsIntoOneWrite() async throws {
    let filePath = "/project/index.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high
      )
    ])
    let fileService = MockProjectFileService(files: [filePath: "<button>Launch</button>"])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-1",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(element: makeElement(), previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.updateEditorContent("<button>One</button>")
      viewModel.updateEditorContent("<button>Two</button>")
    }

    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()
    #expect(writes.count == 1)
    #expect(writes.first == .init(path: filePath, content: "<button>Two</button>"))
  }

  @Test("Changing selection flushes the pending write before loading the next file")
  func reselectionFlushesPendingWrite() async throws {
    let firstFilePath = "/project/index.html"
    let secondFilePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: firstFilePath,
        candidateFilePaths: [firstFilePath],
        confidence: .high
      ),
      makeResolution(
        primaryFilePath: secondFilePath,
        candidateFilePaths: [secondFilePath],
        confidence: .high,
        matchedSelector: ".cta",
        matchedStylesheetPath: secondFilePath,
        allowsInlineStyleEditing: true
      ),
    ])
    let fileService = MockProjectFileService(files: [
      firstFilePath: "<button>Launch</button>",
      secondFilePath: ".cta { color: red; }",
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-2",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .seconds(5)
      )
    }

    await viewModel.inspect(element: makeElement(), previewFilePath: firstFilePath, recentActivities: [])
    await MainActor.run {
      viewModel.updateEditorContent("<button>Updated</button>")
    }

    await viewModel.inspect(
      element: makeElement(selector: ".cta", className: "cta", textContent: ""),
      previewFilePath: secondFilePath,
      recentActivities: []
    )

    let writes = await fileService.recordedWrites()
    let currentFilePath = await MainActor.run { viewModel.currentFilePath }

    #expect(writes == [.init(path: firstFilePath, content: "<button>Updated</button>")])
    #expect(currentFilePath == secondFilePath)
  }

  @Test("Low-confidence matches require explicit file confirmation before writes are enabled")
  func lowConfidenceMatchesRequireExplicitFileSelection() async throws {
    let firstFilePath = "/project/index.html"
    let secondFilePath = "/project/about.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: nil,
        candidateFilePaths: [firstFilePath, secondFilePath],
        confidence: .low
      )
    ])
    let fileService = MockProjectFileService(files: [
      firstFilePath: "<button>Launch</button>",
      secondFilePath: "<button>Launch</button>",
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-3",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(element: makeElement(selector: "button", className: "", textContent: "Launch"), previewFilePath: nil, recentActivities: [])

    let requiresConfirmation = await MainActor.run { viewModel.needsSourceConfirmation }
    let currentFilePathBeforeSelection = await MainActor.run { viewModel.currentFilePath }

    await MainActor.run {
      viewModel.updateEditorContent("<button>Should not write</button>")
    }
    try await Task.sleep(for: .milliseconds(30))
    let writesBeforeSelection = await fileService.recordedWrites()

    #expect(requiresConfirmation)
    #expect(currentFilePathBeforeSelection == nil)
    #expect(writesBeforeSelection.isEmpty)

    await viewModel.selectCandidateFile(secondFilePath)
    await MainActor.run {
      viewModel.updateEditorContent("<button>Confirmed</button>")
    }
    try await Task.sleep(for: .milliseconds(40))

    let currentFilePathAfterSelection = await MainActor.run { viewModel.currentFilePath }
    let writes = await fileService.recordedWrites()

    #expect(currentFilePathAfterSelection == secondFilePath)
    #expect(writes == [.init(path: secondFilePath, content: "<button>Confirmed</button>")])
  }

  @Test("Closing the panel flushes a pending write immediately")
  func closePanelFlushesPendingWrite() async throws {
    let filePath = "/project/index.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high
      )
    ])
    let fileService = MockProjectFileService(files: [filePath: "<button>Launch</button>"])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-4",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .seconds(5)
      )
    }

    await viewModel.inspect(element: makeElement(), previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.updateEditorContent("<button>Saved on close</button>")
    }

    await viewModel.closePanel()

    let writes = await fileService.recordedWrites()
    let isPanelVisible = await MainActor.run { viewModel.isPanelVisible }

    #expect(writes == [.init(path: filePath, content: "<button>Saved on close</button>")])
    #expect(!isPanelVisible)
  }

  @Test("Stylesheet-backed selections expose inline style controls and write CSS changes")
  func stylesheetSelectionsSupportInlineStyleEdits() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta",
        matchedStylesheetPath: filePath,
        allowsInlineStyleEditing: true
      )
    ])
    let fileService = MockProjectFileService(files: [
      filePath: """
      .cta {
        color: #ffffff;
      }
      """
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-5",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(
      element: makeElement(
        selector: ".cta",
        className: "cta",
        textContent: "Launch",
        computedStyles: [
          "font-size": "17px",
          "line-height": "26px",
          "color": "rgb(255, 255, 255)",
        ]
      ),
      previewFilePath: filePath,
      recentActivities: []
    )

    let isDesignValueEditingEnabled = await MainActor.run { viewModel.isDesignValueEditingEnabled }
    let displayedLineHeight = await MainActor.run { viewModel.displayedStyleValue(for: .lineHeight) }
    let lineHeightEditorValue = await MainActor.run { viewModel.editorValue(for: .lineHeight) }
    let widthUnit = await MainActor.run { viewModel.detachedUnit(for: .width) }

    await MainActor.run {
      viewModel.updateStyleEditorValue(.lineHeight, value: "30")
    }
    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()

    #expect(isDesignValueEditingEnabled)
    #expect(displayedLineHeight == "26px")
    #expect(lineHeightEditorValue == "26")
    #expect(widthUnit == "px")
    #expect(writes.count == 1)
    #expect(writes[0].content.contains("line-height: 30px;"))
  }

  @Test("Unique text content can be edited directly from the design panel")
  func contentEditingWritesThroughTheDesignPanel() async throws {
    let filePath = "/project/index.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high
      )
    ])
    let fileService = MockProjectFileService(files: [
      filePath: "<button>Launch</button>"
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-6",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(
      element: makeElement(
        selector: "button",
        className: "",
        textContent: "Launch"
      ),
      previewFilePath: filePath,
      recentActivities: []
    )

    let canEditContent = await MainActor.run { viewModel.canEditContent }

    await MainActor.run {
      viewModel.updateContentValue("Buy now")
    }
    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()

    #expect(canEditContent)
    #expect(writes.count == 1)
    #expect(writes[0].content == "<button>Buy now</button>")
  }
}
