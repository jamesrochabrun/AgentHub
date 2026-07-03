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
        matchedSelector: nil,
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
  matchedSelector: String? = nil
) -> WebPreviewSourceResolution {
  WebPreviewSourceResolution(
    primaryFilePath: primaryFilePath,
    candidateFilePaths: candidateFilePaths,
    confidence: confidence,
    matchedRanges: [:],
    matchedSelector: matchedSelector,
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

/// Polls for debounced writes instead of sleeping a fixed interval — fixed
/// sleeps starve under parallel suite load and indexing an empty array
/// crashes the whole test process.
private func recordedWritesEventually(
  _ fileService: MockProjectFileService,
  count: Int,
  timeoutMilliseconds: Int = 3_000
) async -> [MockProjectFileService.WriteCall] {
  var waited = 0
  while waited < timeoutMilliseconds {
    let writes = await fileService.recordedWrites()
    if writes.count >= count { return writes }
    try? await Task.sleep(for: .milliseconds(10))
    waited += 10
  }
  return await fileService.recordedWrites()
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

    let writes = await recordedWritesEventually(fileService, count: 1)
    // Give a straggler duplicate write a chance to land before asserting count.
    try await Task.sleep(for: .milliseconds(40))
    let finalWrites = await fileService.recordedWrites()
    #expect(finalWrites.count == 1)
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
        matchedSelector: ".cta"
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

  @Test("Low-confidence matches require explicit file confirmation before code writes are enabled")
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

    let currentFilePathAfterSelection = await MainActor.run { viewModel.currentFilePath }
    let writes = await recordedWritesEventually(fileService, count: 1)

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

  @Test("Style edits record a pending batch, apply live, and never write files")
  func styleEditsRecordPendingBatchAndNeverWrite() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta"
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
    let pendingCount = await MainActor.run { viewModel.pendingEditCount }
    let handoff = await MainActor.run {
      viewModel.takePendingDesignEditHandoff(previewContext: "dev server at http://localhost:5173")
    }
    let pendingCountAfterHandoff = await MainActor.run { viewModel.pendingEditCount }

    #expect(isDesignValueEditingEnabled)
    #expect(displayedLineHeight == "26px")
    #expect(lineHeightEditorValue == "26")
    #expect(widthUnit == "px")
    #expect(writes.isEmpty)
    #expect(pendingCount == 1)
    #expect(handoff?.instruction.contains("line-height: 26px → 30px") == true)
    #expect(handoff?.instruction.contains("dev server at http://localhost:5173") == true)
    #expect(handoff?.instruction.contains("styles/site.css") == true)
    #expect(pendingCountAfterHandoff == 0)
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

    let writes = await recordedWritesEventually(fileService, count: 1)
    let pendingCount = await MainActor.run { viewModel.pendingEditCount }

    #expect(canEditContent)
    #expect(writes.count == 1)
    #expect(writes.first?.content == "<button>Buy now</button>")
    #expect(pendingCount == 0)
  }

  @Test("Text edits on a dev-server preview batch to the agent instead of writing")
  func textEditsOnDevServerPreviewBatchToAgent() async throws {
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
        sessionID: "session-dev-server-text",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        liveEditApplier: liveEditApplier,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(selector: "button", className: "", textContent: "Launch")

    // previewFilePath is nil for dev-server previews — the loaded source file
    // is not the file being served, so direct text writes are not provable.
    await viewModel.inspect(element: element, previewFilePath: nil, recentActivities: [])
    await MainActor.run {
      viewModel.updateContentValue("Buy now")
    }
    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()
    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let handoff = await MainActor.run { viewModel.takePendingDesignEditHandoff(previewContext: nil) }

    #expect(writes.isEmpty)
    #expect(liveEdits == [DesignEdit(element: element, action: .updateTextContent("Buy now"))])
    #expect(handoff?.instruction.contains("text content: \"Launch\" → \"Buy now\"") == true)
  }

  @Test("Font-size units stay detached and the color picker batches CSS color values")
  func fontSizeUnitsAndColorPickerBatchNormalizedStyles() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta"
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

    let writes = await fileService.recordedWrites()
    let styleChanges = await MainActor.run { viewModel.pendingEditBatch?.styleChanges }

    #expect(fontSizeEditorValue == "1.05")
    #expect(fontSizeUnit == "rem")
    #expect(writes.isEmpty)
    #expect(styleChanges == [
      WebPreviewPendingStyleChange(property: "font-size", oldValue: "1.05rem", newValue: "2rem"),
      WebPreviewPendingStyleChange(property: "background-color", oldValue: "rgb(12, 34, 56)", newValue: "#224466"),
    ])
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

  @Test("Elements without a direct source mapping still expose design controls")
  func elementsWithoutDirectMappingStillExposeDesignControls() async throws {
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
      element: makeElement(tagName: "SPAN", selector: "span", className: "", textContent: "Launch"),
      previewFilePath: filePath,
      recentActivities: []
    )

    let selectedTab = await MainActor.run { viewModel.selectedTab }
    let hasEditableDesignControls = await MainActor.run { viewModel.hasEditableDesignControls }
    let canEditContent = await MainActor.run { viewModel.canEditContent }

    await MainActor.run {
      viewModel.updateContentValue("Buy now")
    }
    try await Task.sleep(for: .milliseconds(40))

    let writes = await fileService.recordedWrites()
    let pendingCount = await MainActor.run { viewModel.pendingEditCount }

    #expect(selectedTab == .design)
    #expect(hasEditableDesignControls)
    #expect(canEditContent)
    #expect(writes.isEmpty)
    #expect(pendingCount == 1)
  }

  @Test("Toolbar edits batch normalized style values and fit-content records both dimensions")
  func toolbarEditsRecordPendingBatch() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta"
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
    let pendingCount = await MainActor.run { viewModel.pendingEditCount }
    let handoff = await MainActor.run { viewModel.takePendingDesignEditHandoff(previewContext: nil) }

    #expect(writes.isEmpty)
    #expect(pendingCount == 4)
    #expect(handoff?.instruction.contains("margin") == true)
    #expect(handoff?.instruction.contains("24px") == true)
    #expect(handoff?.instruction.contains("text-align") == true)
    #expect(handoff?.instruction.contains("- width:") == true)
    #expect(handoff?.instruction.contains("- height:") == true)
    #expect(handoff?.instruction.contains("fit-content") == true)
    #expect(toolbarMargin == "24px")
    #expect(toolbarAlignment == .center)
    #expect(displayedMargin == "24px")
  }

  @Test("Toolbar edits are propagated to the live preview immediately and never write")
  func toolbarEditsPropagateToLivePreviewImmediately() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta"
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
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(selector: ".cta", className: "cta", textContent: "Launch")

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.margin, value: "24px")))
    }

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    #expect(liveEdits == [DesignEdit(element: element, action: .updateProperty(.margin, value: "24px"))])

    try await Task.sleep(for: .milliseconds(40))
    let writes = await fileService.recordedWrites()
    #expect(writes.isEmpty)
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

    let writes = await recordedWritesEventually(fileService, count: 1)
    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let toolbarText = await MainActor.run { viewModel.toolbarValues?.textContent }
    let displayedText = await MainActor.run { viewModel.contentDisplayText }

    #expect(liveEdits == [DesignEdit(element: element, action: .updateTextContent("Buy now"))])
    #expect(writes.count == 1)
    #expect(writes.first?.content == "<button>Buy now</button>")
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
    let writes = await recordedWritesEventually(fileService, count: 1)
    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }

    #expect(canEditContent)
    #expect(liveEdits == [
      DesignEdit(
        element: element,
        action: .updateTextContent("Manage Claude Codeand Codex and Claude CLI from one native hub.")
      )
    ])
    #expect(writes.count == 1)
    #expect(writes.first?.content.contains(
      #"<h1 class="hero-title">Manage Claude Code<br>and Codex and Claude CLI <span class="accent">from one native hub.</span></h1>"#
    ) == true)
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
    let writes = await recordedWritesEventually(fileService, count: 1)
    let canEditContent = await MainActor.run { viewModel.canEditContent }

    #expect(canEditContent)
    #expect(writes.count == 1)
    #expect(writes.first?.content == "<button>Go</button>")
  }

  @Test("Ambiguous text edits batch to the agent instead of writing")
  func ambiguousTextEditsBatchToAgent() async throws {
    let filePath = "/project/index.html"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high
      )
    ])
    let fileService = MockProjectFileService(files: [
      filePath: "<div><button>Launch</button><button>Launch</button></div>"
    ])
    let liveEditApplier = MockWebPreviewLiveEditApplier()
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-ambiguous-text-toolbar",
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
    let textChange = await MainActor.run { viewModel.pendingEditBatch?.textChange }

    #expect(liveEdits == [DesignEdit(element: element, action: .updateTextContent("Buy now"))])
    #expect(writes.isEmpty)
    #expect(textChange == WebPreviewPendingTextChange(oldText: "Launch", newText: "Buy now"))
  }

  @Test("Design rail edits propagate to the live preview")
  func railEditsPropagateToLivePreview() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta"
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
        matchedSelector: ".first"
      ),
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".second"
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
    let second = makeElement(
      selector: ".second",
      className: "second",
      textContent: "Two",
      computedStyles: ["color": "blue"]
    )

    await viewModel.inspect(element: first, previewFilePath: filePath, recentActivities: [])
    await viewModel.inspect(element: second, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: first, action: .updateProperty(.color, value: "green")))
    }
    try await Task.sleep(for: .milliseconds(40))

    let liveEdits = await MainActor.run { liveEditApplier.appliedEdits }
    let writes = await fileService.recordedWrites()
    let pendingCount = await MainActor.run { viewModel.pendingEditCount }
    let displayedTextColor = await MainActor.run { viewModel.displayedStyleValue(for: .textColor) }

    #expect(liveEdits.isEmpty)
    #expect(writes.isEmpty)
    #expect(pendingCount == 0)
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
        matchedSelector: ".cta"
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

  @Test("Reverting a style edit to its original value cancels the pending change")
  func revertingStyleEditCancelsPendingChange() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta"
      )
    ])
    let fileService = MockProjectFileService(files: [filePath: ".cta { line-height: 26px; }"])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-revert",
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
      computedStyles: ["line-height": "26px"]
    )

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "30px")))
    }
    let pendingAfterEdit = await MainActor.run { viewModel.pendingEditCount }

    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "26px")))
    }
    let pendingAfterRevert = await MainActor.run { viewModel.pendingEditCount }
    let handoff = await MainActor.run { viewModel.takePendingDesignEditHandoff(previewContext: nil) }

    #expect(pendingAfterEdit == 1)
    #expect(pendingAfterRevert == 0)
    #expect(handoff == nil)
  }

  @Test("Design edits record a pending batch even for low-confidence source matches")
  func lowConfidenceElementsStillRecordDesignEdits() async throws {
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: nil,
        candidateFilePaths: ["/project/a.html", "/project/b.html"],
        confidence: .low
      )
    ])
    let fileService = MockProjectFileService(files: [
      "/project/a.html": "<button>Launch</button>",
      "/project/b.html": "<button>Launch</button>",
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-low-confidence-design",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(computedStyles: ["color": "rgb(0, 0, 0)"])

    await viewModel.inspect(element: element, previewFilePath: nil, recentActivities: [])

    let needsConfirmation = await MainActor.run { viewModel.needsSourceConfirmation }
    let isDesignValueEditingEnabled = await MainActor.run { viewModel.isDesignValueEditingEnabled }

    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.color, value: "#ff0000")))
    }
    try await Task.sleep(for: .milliseconds(30))

    let writes = await fileService.recordedWrites()
    let pendingCount = await MainActor.run { viewModel.pendingEditCount }

    #expect(needsConfirmation)
    #expect(isDesignValueEditingEnabled)
    #expect(writes.isEmpty)
    #expect(pendingCount == 1)
  }

  @Test("Inspecting a new element clears the previous pending batch")
  func inspectClearsPreviousPendingBatch() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".first"
      ),
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".second"
      ),
    ])
    let fileService = MockProjectFileService(files: [
      filePath: ".first { color: red; } .second { color: blue; }"
    ])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-batch-reset",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let first = makeElement(selector: ".first", className: "first", textContent: "One")
    let second = makeElement(selector: ".second", className: "second", textContent: "Two")

    await viewModel.inspect(element: first, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: first, action: .updateProperty(.color, value: "green")))
    }
    let pendingBeforeReselect = await MainActor.run { viewModel.pendingEditCount }

    await viewModel.inspect(element: second, previewFilePath: filePath, recentActivities: [])
    let pendingAfterReselect = await MainActor.run { viewModel.pendingEditCount }

    #expect(pendingBeforeReselect == 1)
    #expect(pendingAfterReselect == 0)
  }

  @Test("Discarding pending edits empties the batch without a handoff")
  func discardPendingEditsEmptiesBatch() async throws {
    let filePath = "/project/styles/site.css"
    let resolver = MockWebPreviewSourceResolver(queuedResolutions: [
      makeResolution(
        primaryFilePath: filePath,
        candidateFilePaths: [filePath],
        confidence: .high,
        matchedSelector: ".cta"
      )
    ])
    let fileService = MockProjectFileService(files: [filePath: ".cta { color: red; }"])
    let viewModel = await MainActor.run {
      WebPreviewInspectorViewModel(
        sessionID: "session-discard",
        projectPath: "/project",
        sourceResolver: resolver,
        fileService: fileService,
        writeDebounceDuration: .milliseconds(10)
      )
    }
    let element = makeElement(selector: ".cta", className: "cta", textContent: "Launch")

    await viewModel.inspect(element: element, previewFilePath: filePath, recentActivities: [])
    await MainActor.run {
      viewModel.apply(DesignEdit(element: element, action: .updateProperty(.color, value: "green")))
      viewModel.discardPendingEdits()
    }

    let pendingCount = await MainActor.run { viewModel.pendingEditCount }
    let handoff = await MainActor.run { viewModel.takePendingDesignEditHandoff(previewContext: nil) }

    #expect(pendingCount == 0)
    #expect(handoff == nil)
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
