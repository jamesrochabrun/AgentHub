import Canvas
import Foundation
import Testing
import WebKit

@testable import AgentHubCore

@MainActor
private final class MockSourceHintCapture: WebPreviewSourceHintCapturing {
  var hints: [WebPreviewElementSourceHint]

  init(hints: [WebPreviewElementSourceHint]) {
    self.hints = hints
  }

  func captureSourceHints(
    selector: String,
    in webView: WKWebView
  ) async -> [WebPreviewElementSourceHint] {
    hints
  }
}

@MainActor
private final class MockStaticStyleResolver: WebPreviewStaticStyleResolving {
  var targets: [String: WebPreviewDirectStyleTarget]

  init(targets: [String: WebPreviewDirectStyleTarget] = [:]) {
    self.targets = targets
  }

  func resolveDirectTargets(
    elementSelector: String,
    servedFilePath: String,
    projectPath: String,
    properties: [String],
    in webView: WKWebView
  ) async -> [String: WebPreviewDirectStyleTarget] {
    targets
  }
}

@MainActor
private final class MockProvenanceCapture: WebPreviewStyleProvenanceCapturing {
  var result: WebPreviewStyleProvenance?

  init(result: WebPreviewStyleProvenance?) {
    self.result = result
  }

  func captureProvenance(
    selector: String,
    properties: [String],
    in webView: WKWebView
  ) async -> WebPreviewStyleProvenance? {
    result
  }
}

private actor MockStylesheetMapper: StylesheetSourceMapping {
  private let result: StylesheetMappingResult

  init(result: StylesheetMappingResult) {
    self.result = result
  }

  func mapToProvenFile(
    ruleLocator: WebPreviewCSSRuleLocator,
    context: WebPreviewStylesheetPreviewContext
  ) async -> StylesheetMappingResult {
    result
  }
}

private actor MockDirectWriter: WebPreviewDirectCSSWriting {
  struct Call: Equatable, Sendable {
    let edit: CSSDeclarationEdit
    let filePath: String
    let expectedSHA256: String
  }

  private var outcomes: [DirectWriteOutcome]
  private var calls: [Call] = []

  init(outcomes: [DirectWriteOutcome]) {
    self.outcomes = outcomes
  }

  func write(
    edit: CSSDeclarationEdit,
    filePath: String,
    embeddedStyleBlockIndex: Int?,
    expectedSHA256: String,
    projectPath: String
  ) async -> DirectWriteOutcome {
    calls.append(Call(edit: edit, filePath: filePath, expectedSHA256: expectedSHA256))
    return outcomes.isEmpty ? .editFailed("no outcome queued") : outcomes.removeFirst()
  }

  func recordedCalls() -> [Call] {
    calls
  }
}

private actor TierMockFileService: ProjectFileServiceProtocol {
  struct WriteCall: Equatable, Sendable {
    let path: String
    let content: String
  }

  enum MockError: Error {
    case missingFile
  }

  private var files: [String: String]
  private var writes: [WriteCall] = []

  init(files: [String: String]) {
    self.files = files
  }

  func readFile(at path: String, projectPath: String) async throws -> String {
    guard let content = files[path] else { throw MockError.missingFile }
    return content
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    files[path] = content
    writes.append(WriteCall(path: path, content: content))
  }

  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String] {
    files.keys.sorted()
  }

  func recordedWrites() -> [WriteCall] {
    writes
  }
}

private actor TierMockResolver: WebPreviewSourceResolverProtocol {
  func resolveSource(
    for element: ElementInspectorData,
    projectPath: String,
    previewFilePath: String?,
    recentActivities: [ActivityEntry]
  ) async -> WebPreviewSourceResolution {
    WebPreviewSourceResolution(
      primaryFilePath: previewFilePath,
      candidateFilePaths: previewFilePath.map { [$0] } ?? [],
      confidence: .high,
      matchedRanges: [:],
      matchedSelector: element.cssSelector,
      matchedText: nil
    )
  }
}

private func makeTierElement() -> ElementInspectorData {
  ElementInspectorData(
    tagName: "BUTTON",
    elementId: "",
    className: "cta",
    textContent: "Launch",
    outerHTML: "",
    cssSelector: ".cta",
    computedStyles: ["line-height": "26px"],
    boundingRect: .zero,
    parentTagName: "",
    parentStyles: [:],
    children: ElementRelationships(),
    siblings: ElementRelationships()
  )
}

private func makeProvenance() -> WebPreviewStyleProvenance {
  WebPreviewStyleProvenance(
    winners: [
      WebPreviewPropertyWinner(
        property: "line-height",
        declaredValue: "26px",
        isInline: false,
        isImportant: false,
        rule: WebPreviewCSSRuleLocator(
          stylesheetHref: "file:///project/styles/site.css",
          styleSheetIndex: 0,
          ruleIndexPath: [1, 0],
          selectorText: ".cta",
          specificity: [0, 1, 0],
          ownerNodeAttributes: [:]
        ),
        uncertainties: []
      )
    ],
    unreadableSheetHrefs: [],
    hasAdoptedSheets: false
  )
}

@MainActor
private func waitUntil(
  timeoutMilliseconds: Int = 2_000,
  _ condition: @MainActor () -> Bool
) async throws {
  var waited = 0
  while !condition(), waited < timeoutMilliseconds {
    try await Task.sleep(for: .milliseconds(10))
    waited += 10
  }
}

@MainActor
@Suite("WebPreviewInspectorViewModel tier routing")
struct WebPreviewInspectorViewModelTierRoutingTests {
  private static let cssPath = "/project/styles/site.css"
  private static let indexPath = "/project/index.html"
  /// CSSOM provenance + mapper path (static previews route through the
  /// static resolver instead — covered by its own test below).
  private static let context = WebPreviewStylesheetPreviewContext.devServer(
    baseURL: URL(string: "http://localhost:5173")!,
    projectPath: "/project"
  )

  private func makeViewModel(
    coordinator: MockDirectWriter,
    fileService: TierMockFileService,
    mapperResult: StylesheetMappingResult = .proven(filePath: cssPath, contentSHA256: "baseline-sha"),
    flagEnabled: Bool = true,
    sourceHints: [WebPreviewElementSourceHint] = [],
    staticTargets: [String: WebPreviewDirectStyleTarget] = [:]
  ) -> (WebPreviewInspectorViewModel, WKWebView) {
    let webView = WKWebView()
    let viewModel = WebPreviewInspectorViewModel(
      sessionID: "session-tier",
      projectPath: "/project",
      sourceResolver: TierMockResolver(),
      fileService: fileService,
      writeDebounceDuration: .milliseconds(10),
      styleProvenanceCapture: MockProvenanceCapture(result: makeProvenance()),
      sourceHintCapture: MockSourceHintCapture(hints: sourceHints),
      stylesheetSourceMapper: MockStylesheetMapper(result: mapperResult),
      staticStyleResolver: MockStaticStyleResolver(targets: staticTargets),
      directWriteCoordinator: coordinator,
      isDirectCSSWriteEnabled: { flagEnabled }
    )
    viewModel.registerWebView(webView)
    return (viewModel, webView)
  }

  @Test("Provable properties write through the coordinator, not the batch")
  func provablePropertyWritesDirectly() async throws {
    let coordinator = MockDirectWriter(outcomes: [.written(newSHA256: "next-sha")])
    let fileService = TierMockFileService(files: [Self.indexPath: "<button class=\"cta\">Launch</button>"])
    let (viewModel, webView) = makeViewModel(coordinator: coordinator, fileService: fileService)
    defer { _ = webView }
    let element = makeTierElement()

    await viewModel.inspect(
      element: element,
      previewFilePath: Self.indexPath,
      recentActivities: [],
      stylesheetContext: Self.context
    )
    try await waitUntil { viewModel.styleTiers["line-height"] != nil }

    #expect(viewModel.styleTiers["line-height"] == .direct(WebPreviewDirectStyleTarget(
      filePath: Self.cssPath,
      ruleIndexPath: [1, 0],
      contentSHA256: "baseline-sha"
    )))
    #expect(viewModel.persistenceTierLabel == "Edits site.css directly")

    viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "30px")))

    try await waitUntil {
      if case .direct(let target) = viewModel.styleTiers["line-height"] {
        return target.contentSHA256 == "next-sha"
      }
      return false
    }
    let calls = await coordinator.recordedCalls()

    #expect(calls == [MockDirectWriter.Call(
      edit: CSSDeclarationEdit(ruleIndexPath: [1, 0], property: "line-height", value: "30px"),
      filePath: Self.cssPath,
      expectedSHA256: "baseline-sha"
    )])
    #expect(viewModel.pendingEditCount == 0)
    #expect(viewModel.styleTiers["line-height"] == .direct(WebPreviewDirectStyleTarget(
      filePath: Self.cssPath,
      ruleIndexPath: [1, 0],
      contentSHA256: "next-sha"
    )))
  }

  @Test("Baseline drift downgrades the property to the agent batch")
  func driftDowngradesToAgentBatch() async throws {
    let coordinator = MockDirectWriter(outcomes: [.baselineDrift])
    let fileService = TierMockFileService(files: [Self.indexPath: "<button class=\"cta\">Launch</button>"])
    let (viewModel, webView) = makeViewModel(coordinator: coordinator, fileService: fileService)
    defer { _ = webView }
    let element = makeTierElement()

    await viewModel.inspect(
      element: element,
      previewFilePath: Self.indexPath,
      recentActivities: [],
      stylesheetContext: Self.context
    )
    try await waitUntil { viewModel.styleTiers["line-height"] != nil }

    viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "30px")))
    try await waitUntil { viewModel.pendingEditCount > 0 }

    #expect(viewModel.styleTiers["line-height"] == .agent)
    #expect(viewModel.pendingEditCount == 1)

    let handoff = viewModel.takePendingDesignEditHandoff(previewContext: nil)
    #expect(handoff?.instruction.contains("line-height") == true)
    #expect(handoff?.instruction.contains("30px") == true)
  }

  @Test("With the flag disabled no tiers resolve and edits batch to the agent")
  func disabledFlagKeepsAgentTier() async throws {
    let coordinator = MockDirectWriter(outcomes: [])
    let fileService = TierMockFileService(files: [Self.indexPath: "<button class=\"cta\">Launch</button>"])
    let (viewModel, webView) = makeViewModel(
      coordinator: coordinator,
      fileService: fileService,
      flagEnabled: false
    )
    defer { _ = webView }
    let element = makeTierElement()

    await viewModel.inspect(
      element: element,
      previewFilePath: Self.indexPath,
      recentActivities: [],
      stylesheetContext: Self.context
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(viewModel.styleTiers.isEmpty)
    #expect(viewModel.persistenceTierLabel == "Applies via agent")

    viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "30px")))
    try await Task.sleep(for: .milliseconds(40))

    let calls = await coordinator.recordedCalls()
    #expect(calls.isEmpty)
    #expect(viewModel.pendingEditCount == 1)
  }

  @Test("Static previews resolve direct targets through the static resolver")
  func staticPreviewsUseStaticResolver() async throws {
    let target = WebPreviewDirectStyleTarget(
      filePath: Self.indexPath,
      ruleIndexPath: [0],
      contentSHA256: "html-sha",
      embeddedStyleBlockIndex: 0
    )
    let coordinator = MockDirectWriter(outcomes: [.written(newSHA256: "html-sha-2")])
    let fileService = TierMockFileService(files: [Self.indexPath: "<button class=\"cta\">Launch</button>"])
    let (viewModel, webView) = makeViewModel(
      coordinator: coordinator,
      fileService: fileService,
      staticTargets: ["color": target]
    )
    defer { _ = webView }
    let element = makeTierElement()

    await viewModel.inspect(
      element: element,
      previewFilePath: Self.indexPath,
      recentActivities: [],
      stylesheetContext: .directFile(servedFilePath: Self.indexPath, projectPath: "/project")
    )
    try await waitUntil { viewModel.styleTiers["color"] != nil }

    #expect(viewModel.styleTiers["color"] == .direct(target))
    #expect(viewModel.persistenceTierLabel == "Edits index.html directly")

    viewModel.apply(DesignEdit(element: element, action: .updateProperty(.color, value: "#224466")))
    try await waitUntil {
      if case .direct(let updated) = viewModel.styleTiers["color"] {
        return updated.contentSHA256 == "html-sha-2"
      }
      return false
    }

    let calls = await coordinator.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls.first?.edit == CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "#224466"))
    #expect(viewModel.pendingEditCount == 0)
  }

  @Test("Framework source hints surface in the rail and anchor agent prompts")
  func sourceHintsSurfaceAndAnchorPrompts() async throws {
    let coordinator = MockDirectWriter(outcomes: [])
    let fileService = TierMockFileService(files: [Self.indexPath: "<button class=\"cta\">Launch</button>"])
    let hint = WebPreviewElementSourceHint(
      kind: .svelteMeta,
      file: "src/lib/Button.svelte",
      line: 12,
      column: 4,
      detail: nil
    )
    let (viewModel, webView) = makeViewModel(
      coordinator: coordinator,
      fileService: fileService,
      flagEnabled: false,
      sourceHints: [hint]
    )
    defer { _ = webView }
    let element = makeTierElement()

    await viewModel.inspect(
      element: element,
      previewFilePath: Self.indexPath,
      recentActivities: [],
      stylesheetContext: Self.context
    )
    try await waitUntil { !viewModel.sourceHints.isEmpty }

    #expect(viewModel.primarySourceHintDisplay == "src/lib/Button.svelte:12:4 (svelte)")

    viewModel.apply(DesignEdit(element: element, action: .updateProperty(.lineHeight, value: "30px")))
    let handoff = viewModel.takePendingDesignEditHandoff(previewContext: nil)

    #expect(handoff?.instruction.contains("src/lib/Button.svelte:12:4 (svelte)") == true)
    #expect(handoff?.instruction.contains("Framework source metadata:") == true)
  }

  @Test("Selecting a different element cancels stale provenance results")
  func staleProvenanceIsDiscarded() async throws {
    let coordinator = MockDirectWriter(outcomes: [])
    let fileService = TierMockFileService(files: [Self.indexPath: "<button class=\"cta\">Launch</button>"])
    let (viewModel, webView) = makeViewModel(coordinator: coordinator, fileService: fileService)
    defer { _ = webView }

    await viewModel.inspect(
      element: makeTierElement(),
      previewFilePath: Self.indexPath,
      recentActivities: [],
      stylesheetContext: Self.context
    )
    // Immediately switch elements; the first capture must not land.
    await viewModel.inspect(
      element: makeTierElement(),
      previewFilePath: Self.indexPath,
      recentActivities: [],
      stylesheetContext: nil
    )
    try await Task.sleep(for: .milliseconds(80))

    #expect(viewModel.styleTiers.isEmpty)
  }
}
