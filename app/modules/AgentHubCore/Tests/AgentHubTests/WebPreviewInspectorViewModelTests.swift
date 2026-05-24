import Canvas
import Foundation
import SwiftUI
import Testing
import WebKit

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
  computedStyles: [String: String] = [:],
  parentTagName: String = "",
  parentStyles: [String: String] = [:],
  children: ElementRelationships = ElementRelationships(),
  siblings: ElementRelationships = ElementRelationships()
) -> ElementInspectorData {
  ElementInspectorData(
    tagName: tagName,
    elementId: "",
    className: className,
    textContent: textContent,
    outerHTML: "",
    cssSelector: selector,
    computedStyles: computedStyles,
    boundingRect: .zero,
    parentTagName: parentTagName,
    parentStyles: parentStyles,
    children: children,
    siblings: siblings
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
      viewModel.selectTab(.code)
      viewModel.updateEditorContent("<button>Saved on close</button>")
    }

    await viewModel.closePanel()

    let writes = await fileService.recordedWrites()
    let isPanelVisible = await MainActor.run { viewModel.isPanelVisible }
    let selectedTab = await MainActor.run { viewModel.selectedTab }

    #expect(writes == [.init(path: filePath, content: "<button>Saved on close</button>")])
    #expect(!isPanelVisible)
    #expect(selectedTab == .design)
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

  @Test("Font-size units stay detached and color picker writes CSS color values")
  func fontSizeUnitsAndColorPickerWriteNormalizedStyles() async throws {
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
        font-size: 1.05rem;
        background-color: rgb(12, 34, 56);
      }
      """
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-9",
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
          "font-size": "1.05rem",
          "background-color": "rgb(12, 34, 56)",
        ]
      ),
      previewFilePath: filePath,
      recentActivities: []
    )

    let fontSizeEditorValue = await MainActor.run { viewModel.editorValue(for: .fontSize) }
    let fontSizeUnit = await MainActor.run { viewModel.detachedUnit(for: .fontSize) }

    await MainActor.run {
      viewModel.updateStyleEditorValue(.fontSize, value: "2")
      viewModel.updateColorValue(.backgroundColor, color: Color(hex: "#224466"))
    }
    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()

    #expect(fontSizeEditorValue == "1.05")
    #expect(fontSizeUnit == "rem")
    #expect(writes.count == 1)
    #expect(writes[0].content.contains("font-size: 2rem;"))
    #expect(writes[0].content.contains("background-color: #224466;"))
  }

  @Test("Selected tab persists across element reselection while the rail stays open")
  func selectedTabPersistsAcrossInspectCalls() async throws {
    let firstFilePath = "/project/index.html"
    let secondFilePath = "/project/about.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: firstFilePath,
        candidateFilePaths: [firstFilePath],
        confidence: .high
      ),
      makeResolution(
        primaryFilePath: secondFilePath,
        candidateFilePaths: [secondFilePath],
        confidence: .high
      ),
    ])
    let fileService = MockProjectFileService(files: [
      firstFilePath: "<button>Launch</button>",
      secondFilePath: "<button>Learn more</button>",
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-7",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(
      element: makeElement(selector: "button", className: "", textContent: "Launch"),
      previewFilePath: firstFilePath,
      recentActivities: []
    )
    await MainActor.run {
      viewModel.selectTab(.code)
    }

    await viewModel.inspect(
      element: makeElement(selector: "button", className: "", textContent: "Learn more"),
      previewFilePath: secondFilePath,
      recentActivities: []
    )

    let selectedTab = await MainActor.run { viewModel.selectedTab }
    #expect(selectedTab == .code)
  }

  @Test("Unsupported elements keep the design tab visible with a code fallback message")
  func unsupportedElementsExposeDesignFallbackMessage() async throws {
    let filePath = "/project/index.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high
      )
    ])
    let fileService = MockProjectFileService(files: [filePath: "<div><span>Launch</span><span>Launch</span></div>"])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-8",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(
      element: makeElement(selector: "span", className: "", textContent: "Launch"),
      previewFilePath: filePath,
      recentActivities: []
    )

    let selectedTab = await MainActor.run { viewModel.selectedTab }
    let hasEditableDesignControls = await MainActor.run { viewModel.hasEditableDesignControls }
    let designTabMessage = await MainActor.run { viewModel.designTabMessage }

    #expect(selectedTab == .design)
    #expect(!hasEditableDesignControls)
    #expect(designTabMessage == "This element does not have a safe design mapping. Edit it in Code mode.")
  }

  @Test("Toolbar edits update normalized style values and fit-content writes both dimensions")
  func toolbarEditsWriteThroughTheInspectorViewModel() async throws {
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
        margin: 12px;
        text-align: left;
      }
      """
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-10",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    let element = makeElement(
      selector: ".cta",
      className: "cta",
      textContent: "Launch",
      computedStyles: [
        "display": "flex",
        "margin-top": "12px",
        "margin-right": "12px",
        "margin-bottom": "12px",
        "margin-left": "12px",
        "text-align": "left",
      ]
    )

    await viewModel.inspect(
      element: element,
      previewFilePath: filePath,
      recentActivities: []
    )

    await MainActor.run {
      viewModel.apply(
        DesignEdit(
          element: element,
          action: .updateProperty(.margin, value: "24px")
        )
      )
      viewModel.apply(
        DesignEdit(
          element: element,
          action: .updateProperty(.textAlign, value: "center")
        )
      )
      viewModel.apply(
        DesignEdit(
          element: element,
          action: .fitContent
        )
      )
    }
    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()
    let toolbarMargin = await MainActor.run { viewModel.toolbarValues?.margin }
    let toolbarAlignment = await MainActor.run { viewModel.toolbarValues?.textAlign }
    let displayedMargin = await MainActor.run { viewModel.displayedStyleValue(for: .margin) }

    #expect(writes.count == 1)
    #expect(writes[0].content.contains("margin: 24px;"))
    #expect(writes[0].content.contains("text-align: center;"))
    #expect(writes[0].content.contains("width: fit-content;"))
    #expect(writes[0].content.contains("height: fit-content;"))
    #expect(toolbarMargin == "24px")
    #expect(toolbarAlignment == .center)
    #expect(displayedMargin == "24px")
  }

  @Test("Toolbar edits are propagated to the live preview before the debounced write")
  func toolbarEditsPropagateToLivePreviewImmediately() async throws {
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
        margin: 12px;
      }
      """
    ])
    let liveEditApplier = MockWebPreviewLiveEditApplier()
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-live-toolbar",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        liveEditApplier: liveEditApplier,
        writeDebounceDuration: .milliseconds(50)
      )
    }
    let element = makeElement(selector: ".cta", className: "cta", textContent: "Launch")

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.margin, value: "24px")))
    }

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let writesBeforeDebounce = await fileService.recordedWrites()

    #expect(liveEdits == [DesignEdit(element: element, action: .updateProperty(.margin, value: "24px"))])
    #expect(writesBeforeDebounce.isEmpty)

    try await Task.sleep(for: .milliseconds(90))
    let writes = await fileService.recordedWrites()
    #expect(writes.count == 1)
    #expect(writes[0].content.contains("margin: 24px;"))
  }

  @Test("Toolbar text edits update live preview and source")
  func toolbarTextEditsUpdateLivePreviewAndSource() async throws {
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
    let liveEditApplier = MockWebPreviewLiveEditApplier()
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-live-text-toolbar",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        liveEditApplier: liveEditApplier,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(selector: "button", className: "", textContent: "Launch")

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateTextContent("Buy now")))
    }
    try await Task.sleep(for: .milliseconds(40))

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let writes = await fileService.recordedWrites()
    let toolbarText = await MainActor.run { viewModel.toolbarValues?.textContent }
    let displayedText = await MainActor.run { viewModel.contentDisplayText }

    #expect(liveEdits == [DesignEdit(element: element, action: .updateTextContent("Buy now"))])
    #expect(writes.count == 1)
    #expect(writes[0].content == "<button>Buy now</button>")
    #expect(toolbarText == "Buy now")
    #expect(displayedText == "Buy now")
  }

  @Test("Toolbar text edits preserve nested inline markup")
  func toolbarTextEditsPreserveNestedInlineMarkup() async throws {
    let filePath = "/project/index.html"
    let originalContent = """
    <header class="hero">
      <h1 class="hero-title">Manage Claude Code<br>and Codex CLI <span class="accent">from one native hub.</span></h1>
    </header>
    """
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".hero-title"
      )
    ])
    let fileService = MockProjectFileService(files: [filePath: originalContent])
    let liveEditApplier = MockWebPreviewLiveEditApplier()
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-structured-text-toolbar",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        liveEditApplier: liveEditApplier,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(
      tagName: "H1",
      selector: ".hero-title",
      className: "hero-title",
      textContent: "Manage Claude Codeand Codex CLI from one native hub."
    )

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    let canEditContent = await MainActor.run { viewModel.canEditContent }

    await MainActor.run {
      viewModel.apply(DesignEdit(
        element: element,
        action: .updateTextContent("Manage Claude Codeand Codex and Claude CLI from one native hub.")
      ))
    }
    try await Task.sleep(for: .milliseconds(40))

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let writes = await fileService.recordedWrites()

    #expect(canEditContent)
    #expect(liveEdits == [
      DesignEdit(
        element: element,
        action: .updateTextContent("Manage Claude Codeand Codex and Claude CLI from one native hub.")
      )
    ])
    #expect(writes.count == 1)
    #expect(writes[0].content.contains(
      #"<h1 class="hero-title">Manage Claude Code<br>and Codex and Claude CLI <span class="accent">from one native hub.</span></h1>"#
    ))
  }

  @Test("Clearing toolbar text keeps source range editable for follow-up typing")
  func clearingToolbarTextKeepsSourceRangeEditable() async throws {
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
        sessionID: "session-clear-text-toolbar",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(selector: "button", className: "", textContent: "Launch")

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateTextContent("")))
      viewModel.refreshFromLiveElement(makeElement(selector: "button", className: "", textContent: ""))
      viewModel.apply(DesignEdit(element: element, action: .updateTextContent("Go")))
    }
    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()
    let canEditContent = await MainActor.run { viewModel.canEditContent }

    #expect(canEditContent)
    #expect(writes.count == 1)
    #expect(writes[0].content == "<button>Go</button>")
  }

  @Test("Toolbar text edits do not mutate live preview without source text mapping")
  func toolbarTextEditsRequireSourceTextMapping() async throws {
    let filePath = "/project/index.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high
      )
    ])
    let fileService = MockProjectFileService(files: [
      filePath: "<button>Launch</button><a>Launch</a>"
    ])
    let liveEditApplier = MockWebPreviewLiveEditApplier()
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-unsafe-text-toolbar",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        liveEditApplier: liveEditApplier,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(selector: "button", className: "", textContent: "Launch")

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateTextContent("Buy now")))
    }
    try await Task.sleep(for: .milliseconds(40))

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let writes = await fileService.recordedWrites()

    #expect(liveEdits.isEmpty)
    #expect(writes.isEmpty)
  }

  @Test("Design rail edits propagate to the live preview")
  func railEditsPropagateToLivePreview() async throws {
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
        font-size: 16px;
      }
      """
    ])
    let liveEditApplier = MockWebPreviewLiveEditApplier()
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-live-rail",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        liveEditApplier: liveEditApplier,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(selector: ".cta", className: "cta", textContent: "Launch")

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.updateStyleEditorValue(.fontSize, value: "20")
    }

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }

    #expect(liveEdits == [DesignEdit(element: element, action: .updateProperty(.fontSize, value: "20px"))])
  }

  @Test("Stale toolbar edits are ignored after selecting another element")
  func staleToolbarEditsAreIgnored() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".first",
        matchedStylesheetPath: filePath,
        allowsInlineStyleEditing: true
      ),
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".second",
        matchedStylesheetPath: filePath,
        allowsInlineStyleEditing: true
      ),
    ])
    let fileService = MockProjectFileService(files: [
      filePath: """
      .first {
        color: red;
      }
      .second {
        color: blue;
      }
      """
    ])
    let liveEditApplier = MockWebPreviewLiveEditApplier()
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-stale-live-edit",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        liveEditApplier: liveEditApplier,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let first = makeElement(selector: ".first", className: "first", textContent: "One")
    let second = makeElement(selector: ".second", className: "second", textContent: "Two")

    await viewModel.inspect(element: first, previewFilePath: filePath, recentActivities: [])
    await viewModel.inspect(element: second, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: first, action: .updateProperty(.color, value: "green")))
    }
    try await Task.sleep(for: .milliseconds(40))

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let writes = await fileService.recordedWrites()
    let displayedTextColor = await MainActor.run { viewModel.displayedStyleValue(for: .textColor) }

    #expect(liveEdits.isEmpty)
    #expect(writes.isEmpty)
    #expect(displayedTextColor == "blue")
  }

  @Test("Live element updates refresh rail data without clearing mapped source")
  func liveElementUpdatesRefreshRailDataWithoutClearingSource() async throws {
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
        line-height: 24px;
      }
      """
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-live-refresh",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(
      selector: ".cta",
      className: "cta",
      textContent: "Launch",
      computedStyles: ["font-size": "16px", "line-height": "24px"]
    )
    let refreshed = makeElement(
      selector: ".cta",
      className: "cta",
      textContent: "Buy now",
      computedStyles: ["font-size": "22px", "line-height": "24px"],
      parentStyles: ["display": "grid"]
    )

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.refreshFromLiveElement(refreshed)
    }

    let currentFilePath = await MainActor.run { viewModel.currentFilePath }
    let fileContent = await MainActor.run { viewModel.fileContent }
    let contentDisplayText = await MainActor.run { viewModel.contentDisplayText }
    let toolbarText = await MainActor.run { viewModel.toolbarValues?.textContent }
    let displayedFontSize = await MainActor.run { viewModel.displayedStyleValue(for: .fontSize) }
    let displayedLineHeight = await MainActor.run { viewModel.displayedStyleValue(for: .lineHeight) }

    #expect(currentFilePath == filePath)
    #expect(fileContent.contains("line-height: 24px;"))
    #expect(contentDisplayText == "Buy now")
    #expect(toolbarText == "Buy now")
    #expect(displayedFontSize == "22px")
    #expect(displayedLineHeight == "24px")
  }

  @Test("Parent layout context and console state are surfaced for the rail")
  func parentContextAndConsoleEntriesAreExposed() async throws {
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
        sessionID: "session-11",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(
      element: makeElement(
        selector: "button.cta",
        textContent: "Launch",
        parentTagName: "div",
        parentStyles: [
          "display": "flex",
          "justify-content": "center",
          "align-items": "stretch",
          "gap": "16px",
        ],
        siblings: ElementRelationships(
          count: 2,
          items: [
            ElementSummary(tagName: "SPAN", className: "eyebrow", textContent: "New"),
            ElementSummary(tagName: "P", className: "copy", textContent: "Body"),
          ]
        )
      ),
      previewFilePath: filePath,
      recentActivities: []
    )

    await MainActor.run {
      for index in 0..<205 {
        viewModel.appendConsoleEntry(level: index.isMultiple(of: 2) ? "log" : "warn", message: "entry-\(index)")
      }
    }

    let parentTagName = await MainActor.run { viewModel.parentContext?.tagName }
    let parentSummary = await MainActor.run { viewModel.parentContextSummary }
    let siblingCount = await MainActor.run { viewModel.siblingsSummary.count }
    let consoleCount = await MainActor.run { viewModel.consoleEntries.count }
    let firstConsoleEntry = await MainActor.run { viewModel.consoleEntries.first }
    let lastConsoleEntry = await MainActor.run { viewModel.consoleEntries.last }
    let hasConsoleEntries = await MainActor.run { viewModel.hasConsoleEntries }

    #expect(parentTagName == "div")
    #expect(parentSummary == "flex, justify-content: center, align-items: stretch, gap: 16px")
    #expect(siblingCount == 2)
    #expect(consoleCount == 200)
    #expect(firstConsoleEntry == "[WARN] entry-5")
    #expect(lastConsoleEntry == "[LOG] entry-204")
    #expect(hasConsoleEntries)

    await MainActor.run {
      viewModel.clearConsoleEntries()
    }

    let clearedConsoleCount = await MainActor.run { viewModel.consoleEntries.count }
    #expect(clearedConsoleCount == 0)
  }

  @Test("Inline-toolbar edits are reformatted by the reconciler after the direct write")
  func reconcilerOverwritesDirectWriteWithReformattedContent() async throws {
    let filePath = "/project/styles/site.css"
    let originalContent = """
    .cta {
    \tcolor: #ffffff;
    }
    """
    let reconciledContent = """
    .cta {
    \tcolor: #ffffff;
    \tline-height: 30px;
    }
    """
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
    let fileService = MockProjectFileService(files: [filePath: originalContent])
    let reconciler = MockInlineEditStyleReconciler(behavior: .success(reconciledContent))
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-reconcile-success",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        inlineEditReconciler: reconciler,
        writeDebounceDuration: .milliseconds(10),
        reconcileDebounceDuration: .milliseconds(10)
      )
    }

    let element = makeElement(
      selector: ".cta",
      className: "cta",
      textContent: "Launch",
      computedStyles: ["line-height": "26px", "color": "rgb(255, 255, 255)"]
    )

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "30px")))
    }

    try await Task.sleep(for: .milliseconds(150))

    let calls = await reconciler.recordedCalls()
    let writes = await fileService.recordedWrites()

    #expect(calls.count == 1)
    #expect(calls.first?.changeSummary.contains("line-height") == true)
    #expect(calls.first?.changeSummary.contains(".cta") == true)
    #expect(calls.first?.originalContent == originalContent)
    #expect(writes.count == 2)
    #expect(writes.first?.content.contains("line-height: 30px;") == true)
    #expect(writes.last?.content == reconciledContent)
  }

  @Test("Reconciler waits for the reconcile debounce before invoking the CLI")
  func reconcilerWaitsForDebounce() async throws {
    let filePath = "/project/styles/site.css"
    let originalContent = """
    .cta {
      font-size: 68px;
    }
    """
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
    let fileService = MockProjectFileService(files: [filePath: originalContent])
    let reconciler = MockInlineEditStyleReconciler(behavior: .success(originalContent))
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-reconcile-delay",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        inlineEditReconciler: reconciler,
        writeDebounceDuration: .milliseconds(10),
        reconcileDebounceDuration: .milliseconds(80)
      )
    }
    let element = makeElement(
      selector: ".cta",
      className: "cta",
      textContent: "Launch",
      computedStyles: ["font-size": "68px"]
    )

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.fontSize, value: "56px")))
    }

    try await Task.sleep(for: .milliseconds(40))
    let callsBeforeDebounce = await reconciler.recordedCalls()
    #expect(callsBeforeDebounce.isEmpty)

    try await Task.sleep(for: .milliseconds(90))
    let callsAfterDebounce = await reconciler.recordedCalls()
    #expect(callsAfterDebounce.count == 1)
  }

  @Test("Rapid toolbar edits collapse into one reconcile request")
  func rapidToolbarEditsCollapseIntoOneReconcileRequest() async throws {
    let filePath = "/project/styles/site.css"
    let originalContent = """
    .cta {
      font-size: 68px;
    }
    """
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
    let fileService = MockProjectFileService(files: [filePath: originalContent])
    let reconciler = MockInlineEditStyleReconciler(behavior: .success(originalContent))
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-reconcile-rapid",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        inlineEditReconciler: reconciler,
        writeDebounceDuration: .milliseconds(10),
        reconcileDebounceDuration: .milliseconds(80)
      )
    }
    let element = makeElement(
      selector: ".cta",
      className: "cta",
      textContent: "Launch",
      computedStyles: ["font-size": "68px"]
    )

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.fontSize, value: "67px")))
    }
    try await Task.sleep(for: .milliseconds(40))
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.fontSize, value: "56px")))
    }

    try await Task.sleep(for: .milliseconds(140))

    let calls = await reconciler.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls.first?.changeSummary.contains("56px") == true)
  }

  @Test("Reconciler failures leave the direct write untouched")
  func reconcilerFailureKeepsDirectWrite() async throws {
    let filePath = "/project/styles/site.css"
    let originalContent = """
    .cta {
      color: #ffffff;
    }
    """
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
    let fileService = MockProjectFileService(files: [filePath: originalContent])
    let reconciler = MockInlineEditStyleReconciler(
      behavior: .failure(InlineEditStyleReconcilerError.emptyOutput)
    )
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-reconcile-failure",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        inlineEditReconciler: reconciler,
        writeDebounceDuration: .milliseconds(10),
        reconcileDebounceDuration: .milliseconds(10)
      )
    }

    let element = makeElement(
      selector: ".cta",
      className: "cta",
      textContent: "Launch",
      computedStyles: ["line-height": "26px", "color": "rgb(255, 255, 255)"]
    )

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "30px")))
    }

    try await Task.sleep(for: .milliseconds(150))

    let calls = await reconciler.recordedCalls()
    let writes = await fileService.recordedWrites()

    #expect(calls.count == 1)
    #expect(writes.count == 1)
    #expect(writes.first?.content.contains("line-height: 30px;") == true)
  }

  @Test("Editor-only edits (no DesignEdit) skip the reconciler")
  func nonToolbarEditsBypassReconciler() async throws {
    let filePath = "/project/index.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high
      )
    ])
    let fileService = MockProjectFileService(files: [filePath: "<button>Launch</button>"])
    let reconciler = MockInlineEditStyleReconciler(behavior: .success("<button>Reformatted</button>"))
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-reconcile-bypass",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        inlineEditReconciler: reconciler,
        writeDebounceDuration: .milliseconds(10),
        reconcileDebounceDuration: .milliseconds(10)
      )
    }

    await viewModel.inspect(element: makeElement(), previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.updateEditorContent("<button>Edited</button>")
    }

    try await Task.sleep(for: .milliseconds(80))

    let calls = await reconciler.recordedCalls()
    let writes = await fileService.recordedWrites()

    #expect(calls.isEmpty)
    #expect(writes == [.init(path: filePath, content: "<button>Edited</button>")])
  }
}

private actor MockInlineEditStyleReconciler: InlineEditStyleReconcilerProtocol {
  struct Call: Sendable {
    let originalContent: String
    let editedContent: String
    let filePath: String
    let changeSummary: String
    let projectPath: String
  }

  enum Behavior: Sendable {
    case success(String)
    case failure(InlineEditStyleReconcilerError)
  }

  private let behavior: Behavior
  private var calls: [Call] = []

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func recordedCalls() -> [Call] {
    calls
  }

  func reconcile(
    originalContent: String,
    editedContent: String,
    filePath: String,
    changeSummary: String,
    projectPath: String
  ) async throws -> String {
    calls.append(Call(
      originalContent: originalContent,
      editedContent: editedContent,
      filePath: filePath,
      changeSummary: changeSummary,
      projectPath: projectPath
    ))
    switch behavior {
    case .success(let output):
      return output
    case .failure(let error):
      throw error
    }
  }
}

private final class MockWebPreviewLiveEditApplier: WebPreviewLiveEditApplying {
  @MainActor
  private(set) var appliedEdits: [DesignEdit] = []

  @MainActor
  private(set) var refreshCount = 0

  @MainActor
  func apply(_ edit: DesignEdit, in webView: WKWebView?) {
    appliedEdits.append(edit)
  }

  @MainActor
  func refreshSelectedElement(in webView: WKWebView?) {
    refreshCount += 1
  }
}
