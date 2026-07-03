//
//  WebPreviewInspectorViewModel.swift
//  AgentHub
//
//  Source-backed inspector rail state for web preview editing.
//

import AppKit
import Canvas
import Foundation
import SwiftUI
import WebKit

@MainActor
@Observable
final class WebPreviewInspectorViewModel {
  private struct SourceTextSegment {
    let rawRange: Range<String.Index>
    let text: String
    let textStart: Int

    var textEnd: Int {
      textStart + text.count
    }
  }

  private struct SourceTextContentMapping {
    let text: String
    let segments: [SourceTextSegment]
  }

  private struct TextSplice {
    let start: Int
    let end: Int
    let replacement: String
  }

  let sessionID: String
  let projectPath: String

  private let sourceResolver: any WebPreviewSourceResolverProtocol
  private let fileService: any ProjectFileServiceProtocol
  private let liveEditApplier: any WebPreviewLiveEditApplying
  private let writeDebounceDuration: Duration
  private let styleProvenanceCapture: any WebPreviewStyleProvenanceCapturing
  private let sourceHintCapture: any WebPreviewSourceHintCapturing
  private let stylesheetSourceMapper: any StylesheetSourceMapping
  private let staticStyleResolver: any WebPreviewStaticStyleResolving
  private let directWriteCoordinator: any WebPreviewDirectCSSWriting
  private let isDirectCSSWriteEnabled: () -> Bool

  private var pendingWriteTask: Task<Void, Never>?
  private var previewFilePath: String?
  private var stylesheetContext: WebPreviewStylesheetPreviewContext?
  private var provenanceTask: Task<Void, Never>?
  private var sourceHintTask: Task<Void, Never>?
  /// Property → new value for the debounced Tier-1 flush ("" removes).
  private var pendingDirectWrites: [String: String] = [:]
  private var pendingDirectWriteTask: Task<Void, Never>?
  private var trackedTextToken: String?
  private var trackedTextLocation: Int?
  private var trackedStructuredTextContent: SourceTextContentMapping?
  private var userConfirmedLowConfidenceFile = false
  private weak var previewWebView: WKWebView?

  private(set) var selectedElement: ElementInspectorData?
  private(set) var resolution: WebPreviewSourceResolution?
  private(set) var liveProperties: WebPreviewLivePropertiesSnapshot?
  private(set) var selectedElementSnapshot: NSImage?
  private(set) var toolbarValues: DesignToolbarValues?
  private(set) var consoleEntries: [String] = []
  private(set) var pendingEditBatch: WebPreviewPendingDesignEditBatch?
  private(set) var styleTiers: [String: WebPreviewStyleEditTier] = [:]
  private(set) var sourceHints: [WebPreviewElementSourceHint] = []

  var isPanelVisible = false
  var isResolving = false
  var isWriting = false
  var errorMessage: String?
  var writeErrorMessage: String?
  var selectedTab: WebPreviewInspectorTab = .design

  var currentFilePath: String?
  var fileContent = ""
  private(set) var savedFileContent = ""
  private(set) var editorDisplayMode: EditorDisplayMode = .highlighted
  private(set) var editorDocumentID = UUID()
  private(set) var activeCapabilities: Set<WebPreviewEditableCapability> = [.code]
  private(set) var matchedSelector: String?
  private(set) var styleValues: [WebPreviewStyleProperty: String] = [:]

  init(
    sessionID: String,
    projectPath: String,
    sourceResolver: any WebPreviewSourceResolverProtocol = WebPreviewSourceResolver(),
    fileService: any ProjectFileServiceProtocol = ProjectFileService.shared,
    liveEditApplier: any WebPreviewLiveEditApplying = CanvasWebPreviewLiveEditApplier(),
    writeDebounceDuration: Duration = .milliseconds(600),
    styleProvenanceCapture: (any WebPreviewStyleProvenanceCapturing)? = nil,
    sourceHintCapture: (any WebPreviewSourceHintCapturing)? = nil,
    stylesheetSourceMapper: (any StylesheetSourceMapping)? = nil,
    staticStyleResolver: (any WebPreviewStaticStyleResolving)? = nil,
    directWriteCoordinator: (any WebPreviewDirectCSSWriting)? = nil,
    isDirectCSSWriteEnabled: (() -> Bool)? = nil
  ) {
    self.sessionID = sessionID
    self.projectPath = projectPath
    self.sourceResolver = sourceResolver
    self.fileService = fileService
    self.liveEditApplier = liveEditApplier
    self.writeDebounceDuration = writeDebounceDuration
    self.styleProvenanceCapture = styleProvenanceCapture ?? WebPreviewStyleProvenanceCapture()
    self.sourceHintCapture = sourceHintCapture ?? WebPreviewSourceHintCapture()
    self.stylesheetSourceMapper = stylesheetSourceMapper ?? StylesheetSourceMapper(fileService: fileService)
    self.staticStyleResolver = staticStyleResolver ?? WebPreviewStaticStyleResolver(fileService: fileService)
    self.directWriteCoordinator = directWriteCoordinator ?? WebPreviewDirectCSSWriteCoordinator(fileService: fileService)
    self.isDirectCSSWriteEnabled = isDirectCSSWriteEnabled ?? {
      UserDefaults.standard.object(forKey: AgentHubDefaults.webPreviewDirectCSSWriteEnabled) as? Bool ?? true
    }
  }

  var candidateFilePaths: [String] {
    resolution?.candidateFilePaths ?? []
  }

  var shouldShowLowConfidenceFallback: Bool {
    resolution?.isLowConfidence == true
  }

  var needsSourceConfirmation: Bool {
    shouldShowLowConfidenceFallback && !userConfirmedLowConfidenceFile
  }

  var isEditingEnabled: Bool {
    !needsSourceConfirmation && currentFilePath != nil
  }

  var isDesignValueEditingEnabled: Bool {
    selectedElement != nil && !editableStyleProperties.isEmpty
  }

  var canEditContent: Bool {
    selectedElement != nil && activeCapabilities.contains(.content)
  }

  var editableStyleProperties: [WebPreviewStyleProperty] {
    WebPreviewStyleProperty.allCases.filter { activeCapabilities.contains($0.capability) }
  }

  var hasEditableDesignControls: Bool {
    canEditContent || isDesignValueEditingEnabled
  }

  var pendingEditCount: Int {
    pendingEditBatch?.changeCount ?? 0
  }

  /// The most specific framework source hint, for the rail's Source row.
  var primarySourceHintDisplay: String? {
    let best = sourceHints.first(where: { $0.file != nil }) ?? sourceHints.first
    return best?.promptLine
  }

  var persistenceTierLabel: String {
    let directFileNames = Set(styleTiers.values.compactMap { tier -> String? in
      guard case .direct(let target) = tier else { return nil }
      return URL(fileURLWithPath: target.filePath).lastPathComponent
    })
    if directFileNames.count == 1, let name = directFileNames.first {
      return "Edits \(name) directly"
    }
    if directFileNames.count > 1 {
      return "Edits \(directFileNames.count) stylesheets directly"
    }
    return "Applies via agent"
  }

  /// True when the loaded source file is the file being previewed directly
  /// (static preview) — the only case where text edits write straight to disk.
  private var isDirectPreviewTarget: Bool {
    guard let currentFilePath, let previewFilePath else { return false }
    return currentFilePath == previewFilePath
  }

  var selectedTagName: String? {
    selectedElement?.tagName.lowercased().nilIfEmpty
  }

  var selectorSummary: String? {
    matchedSelector ?? selectedElement?.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  var parentContext: ParentLayoutContext? {
    selectedElement?.parentContext
  }

  var parentContextSummary: String? {
    guard let parentContext else { return nil }
    var parts: [String] = []
    if let display = parentContext.display {
      parts.append(display)
    }
    if let justifyContent = parentContext.justifyContent {
      parts.append("justify-content: \(justifyContent)")
    }
    if let alignItems = parentContext.alignItems {
      parts.append("align-items: \(alignItems)")
    }
    if let gap = parentContext.gap {
      parts.append("gap: \(gap)")
    }
    if let position = parentContext.position {
      parts.append("position: \(position)")
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: ", ")
  }

  var childrenSummary: ElementRelationships {
    selectedElement?.children ?? ElementRelationships()
  }

  var siblingsSummary: ElementRelationships {
    selectedElement?.siblings ?? ElementRelationships()
  }

  var confidenceDisplayText: String {
    resolution?.confidence.displayName ?? "No source match"
  }

  var contentDisplayText: String {
    liveProperties?.content ?? "—"
  }

  var hasConsoleEntries: Bool {
    !consoleEntries.isEmpty
  }

  var relativeFilePath: String? {
    guard let currentFilePath else { return nil }
    return displayPath(for: currentFilePath)
  }

  var hasUnsavedChanges: Bool {
    fileContent != savedFileContent
  }

  var saveStatusText: String {
    if let writeErrorMessage {
      return writeErrorMessage
    }
    if isResolving {
      return "Mapping source…"
    }
    if isWriting {
      return "Updating file…"
    }
    if pendingEditCount > 0 {
      return pendingEditCount == 1
        ? "1 design change pending — Apply sends it to the agent"
        : "\(pendingEditCount) design changes pending — Apply sends them to the agent"
    }
    if needsSourceConfirmation {
      return "Choose a source file to enable code editing"
    }
    if hasUnsavedChanges {
      return "Pending update"
    }
    return "Design edits apply via agent"
  }

  func displayPath(for path: String) -> String {
    let normalizedProject = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path
    let normalizedFile = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    guard normalizedFile.hasPrefix(normalizedProject + "/") else {
      return URL(fileURLWithPath: normalizedFile).lastPathComponent
    }
    return String(normalizedFile.dropFirst(normalizedProject.count + 1))
  }

  func metricValue(_ keyPath: KeyPath<WebPreviewLivePropertiesSnapshot, String>) -> String {
    liveProperties?[keyPath: keyPath] ?? "—"
  }

  func typographyValue(
    _ keyPath: KeyPath<WebPreviewLivePropertiesSnapshot, String?>,
    fallbackTo property: WebPreviewStyleProperty? = nil
  ) -> String {
    if let property {
      let mappedValue = displayedStyleValue(for: property)
      if !mappedValue.isEmpty {
        return mappedValue
      }
    }
    return liveProperties?[keyPath: keyPath] ?? "—"
  }

  func displayedStyleValue(for property: WebPreviewStyleProperty) -> String {
    if let value = styleValues[property], !value.isEmpty {
      return value
    }
    return liveProperties?.value(for: property) ?? ""
  }

  func editorValue(for property: WebPreviewStyleProperty) -> String {
    let value = displayedStyleValue(for: property)
    guard let unit = Self.numericComponents(from: value)?.unit,
          let stripped = Self.stripUnit(unit, from: value) else {
      return value
    }
    return stripped
  }

  func detachedUnit(for property: WebPreviewStyleProperty) -> String? {
    if let detectedUnit = Self.numericComponents(from: displayedStyleValue(for: property))?.unit {
      return detectedUnit
    }

    let value = displayedStyleValue(for: property).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? property.fallbackUnit : nil
  }

  func colorValue(for property: WebPreviewStyleProperty) -> Color {
    if let parsedColor = Self.parseColor(from: resolvedColorValue(for: property)) {
      return Color(nsColor: parsedColor)
    }
    return .clear
  }

  func updateColorValue(_ property: WebPreviewStyleProperty, color: Color) {
    guard property.supportsColorPicking else { return }
    updateStyleValue(property, value: Self.serializedColor(from: NSColor(color)))
  }

  func isEditable(_ property: WebPreviewStyleProperty) -> Bool {
    activeCapabilities.contains(property.capability) && isDesignValueEditingEnabled
  }

  func selectTab(_ tab: WebPreviewInspectorTab) {
    selectedTab = tab
  }

  func resetTabSelection() {
    selectedTab = .design
  }

  func registerWebView(_ webView: WKWebView) {
    previewWebView = webView
  }

  func appendConsoleEntry(level: String, message: String) {
    let formatted = "[\(level.uppercased())] \(message)"
    consoleEntries.append(formatted)
    if consoleEntries.count > 200 {
      consoleEntries.removeFirst(consoleEntries.count - 200)
    }
  }

  func clearConsoleEntries() {
    consoleEntries.removeAll()
  }

  func inspect(
    element: ElementInspectorData,
    previewFilePath: String?,
    recentActivities: [ActivityEntry],
    stylesheetContext: WebPreviewStylesheetPreviewContext? = nil
  ) async {
    await flushPendingWriteIfNeeded()

    provenanceTask?.cancel()
    sourceHintTask?.cancel()
    selectedElement = element
    liveProperties = WebPreviewLivePropertiesSnapshot(element: element)
    toolbarValues = DesignToolbarValues(element: element)
    selectedElementSnapshot = nil
    isPanelVisible = true
    isResolving = true
    errorMessage = nil
    writeErrorMessage = nil
    resolution = nil
    pendingEditBatch = nil
    styleTiers = [:]
    sourceHints = []
    pendingDirectWrites = [:]
    self.previewFilePath = previewFilePath
    self.stylesheetContext = stylesheetContext
    currentFilePath = nil
    fileContent = ""
    savedFileContent = ""
    editorDocumentID = UUID()
    trackedTextToken = nil
    trackedTextLocation = nil
    trackedStructuredTextContent = nil
    matchedSelector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    styleValues = [:]
    activeCapabilities = [.code]
    userConfirmedLowConfidenceFile = false

    refreshStyleTiers(for: element)
    refreshSourceHints(for: element)

    let resolved = await sourceResolver.resolveSource(
      for: element,
      projectPath: projectPath,
      previewFilePath: previewFilePath,
      recentActivities: recentActivities
    )

    resolution = resolved
    matchedSelector = resolved.matchedSelector ?? matchedSelector

    await captureElementSnapshot()

    let startingFilePath = resolved.primaryFilePath ?? resolved.candidateFilePaths.first
    guard let startingFilePath else {
      errorMessage = "No editable source files were found for this element."
      recomputeEditingState()
      isResolving = false
      return
    }

    if resolved.isLowConfidence {
      recomputeEditingState()
      isResolving = false
      return
    }

    await loadFile(at: startingFilePath)
    isResolving = false
  }

  func closePanel() async {
    await flushPendingWriteIfNeeded()
    provenanceTask?.cancel()
    provenanceTask = nil
    sourceHintTask?.cancel()
    sourceHintTask = nil
    isPanelVisible = false
    isResolving = false
    isWriting = false
    errorMessage = nil
    writeErrorMessage = nil
    selectedElement = nil
    resolution = nil
    pendingEditBatch = nil
    styleTiers = [:]
    sourceHints = []
    pendingDirectWrites = [:]
    stylesheetContext = nil
    previewFilePath = nil
    liveProperties = nil
    selectedElementSnapshot = nil
    toolbarValues = nil
    currentFilePath = nil
    fileContent = ""
    savedFileContent = ""
    editorDocumentID = UUID()
    activeCapabilities = [.code]
    trackedTextToken = nil
    trackedTextLocation = nil
    trackedStructuredTextContent = nil
    matchedSelector = nil
    styleValues = [:]
    consoleEntries.removeAll()
    userConfirmedLowConfidenceFile = false
    resetTabSelection()
  }

  func selectCandidateFile(_ path: String) async {
    await flushPendingWriteIfNeeded()
    userConfirmedLowConfidenceFile = true
    await loadFile(at: path)
  }

  func updateEditorContent(_ updatedText: String) {
    guard isEditingEnabled else { return }
    fileContent = updatedText
    scheduleWrite()
  }

  func updateContentValue(_ value: String) {
    updateContentValue(value, propagateLiveEdit: true)
  }

  private func updateContentValue(_ value: String, propagateLiveEdit: Bool) {
    guard canEditContent else {
      return
    }

    if isDirectPreviewTarget {
      if let trackedStructuredTextContent,
         let selectedElement,
         let update = Self.updateStructuredTextContent(
          trackedStructuredTextContent,
          in: fileContent,
          to: value,
          element: selectedElement
         ) {
        applyContentUpdate(
          value: value,
          updatedContent: update.content,
          textLocation: nil,
          structuredMapping: update.mapping,
          propagateLiveEdit: propagateLiveEdit
        )
        return
      }

      if let previousTextToken = trackedTextToken,
         let replacementRange = Self.trackedTextRange(
           in: fileContent,
           token: previousTextToken,
           location: trackedTextLocation
         ) {
        let replacementLocation = Self.characterOffset(of: replacementRange, in: fileContent)
        let updatedContent = fileContent.replacingCharacters(in: replacementRange, with: value)
        applyContentUpdate(
          value: value,
          updatedContent: updatedContent,
          textLocation: replacementLocation,
          structuredMapping: nil,
          propagateLiveEdit: propagateLiveEdit
        )
        return
      }
    }

    recordTextEdit(value, propagateLiveEdit: propagateLiveEdit)
  }

  private func applyContentUpdate(
    value: String,
    updatedContent: String,
    textLocation: Int?,
    structuredMapping: SourceTextContentMapping?,
    propagateLiveEdit: Bool
  ) {
    if propagateLiveEdit, let selectedElement {
      liveEditApplier.apply(
        DesignEdit(element: selectedElement, action: .updateTextContent(value)),
        in: previewWebView
      )
    }
    trackedTextToken = value
    trackedTextLocation = textLocation
    trackedStructuredTextContent = structuredMapping
    fileContent = updatedContent
    liveProperties = liveProperties?.updatingContent(value)
    toolbarValues?.textContent = value
    scheduleWrite()
  }

  func updateStyleValue(_ property: WebPreviewStyleProperty, value: String) {
    guard isEditable(property) else { return }
    applyLiveStyleEdit(property: property, value: value)
    recordStyleEdit(propertyName: property.rawValue, value: value)
  }

  func updateStyleEditorValue(_ property: WebPreviewStyleProperty, value: String) {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let unit = preferredUnit(for: property) else {
      updateStyleValue(property, value: trimmedValue)
      return
    }

    guard !trimmedValue.isEmpty else {
      updateStyleValue(property, value: "")
      return
    }

    if Self.numericComponents(from: trimmedValue) != nil || !Self.isPlainNumericValue(trimmedValue) {
      updateStyleValue(property, value: trimmedValue)
      return
    }

    updateStyleValue(property, value: "\(trimmedValue)\(unit)")
  }

  func flushPendingWriteIfNeeded() async {
    pendingWriteTask?.cancel()
    pendingWriteTask = nil
    pendingDirectWriteTask?.cancel()
    pendingDirectWriteTask = nil
    await persistCurrentFileIfNeeded()
    await flushPendingDirectWrites()
  }

  func apply(_ edit: DesignEdit) {
    guard isCurrentEditTarget(edit.element) else { return }

    switch edit.action {
    case .updateProperty(let property, value: let value):
      liveEditApplier.apply(edit, in: previewWebView)
      recordStyleEdit(propertyName: property.rawValue, value: value)
    case .updateTextContent(let value):
      updateContentValue(value, propagateLiveEdit: true)
    case .fitContent:
      liveEditApplier.apply(edit, in: previewWebView)
      recordStyleEdit(propertyName: "width", value: "fit-content")
      recordStyleEdit(propertyName: "height", value: "fit-content")
    case .deleteElement:
      return
    }
  }

  /// Removes and returns the pending batch as an element-anchored agent
  /// instruction. Returns nil when nothing is pending.
  func takePendingDesignEditHandoff(previewContext: String?) -> WebPreviewPendingDesignEditHandoff? {
    guard let batch = pendingEditBatch, !batch.isEmpty else {
      pendingEditBatch = nil
      return nil
    }
    pendingEditBatch = nil

    let candidateFiles = (resolution?.candidateFilePaths ?? []).map { displayPath(for: $0) }
    guard let instruction = WebPreviewDesignEditPromptComposer.instruction(
      for: batch,
      previewContext: previewContext,
      candidateFiles: candidateFiles,
      sourceHints: sourceHints.map(\.promptLine)
    ) else {
      return nil
    }

    return WebPreviewPendingDesignEditHandoff(element: batch.element, instruction: instruction)
  }

  func discardPendingEdits() {
    pendingEditBatch = nil
  }

  func refreshFromLiveElement(_ element: ElementInspectorData) {
    guard isCurrentLiveElementUpdate(element) else { return }
    selectedElement = element
    liveProperties = WebPreviewLivePropertiesSnapshot(element: element)
    toolbarValues = DesignToolbarValues(element: element)

    if matchedSelector == nil {
      matchedSelector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    recomputeEditingState()
  }

  // MARK: - Private

  private func applyLiveStyleEdit(property: WebPreviewStyleProperty, value: String) {
    guard let selectedElement,
          let designProperty = DesignEdit.Property(rawValue: property.rawValue) else {
      return
    }

    liveEditApplier.apply(
      DesignEdit(element: selectedElement, action: .updateProperty(designProperty, value: value)),
      in: previewWebView
    )
  }

  private func isCurrentEditTarget(_ element: ElementInspectorData) -> Bool {
    guard let selectedElement else { return false }
    if element.id == selectedElement.id {
      return true
    }

    let incomingSelector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedSelector = selectedElement.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    if !incomingSelector.isEmpty, incomingSelector == selectedSelector {
      return true
    }

    return !element.elementId.isEmpty && element.elementId == selectedElement.elementId
  }

  private func isCurrentLiveElementUpdate(_ element: ElementInspectorData) -> Bool {
    guard let selectedElement else { return false }
    if element.id == selectedElement.id {
      return true
    }

    let incomingSelector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedSelector = selectedElement.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    if !incomingSelector.isEmpty, incomingSelector == selectedSelector {
      return true
    }

    return !element.elementId.isEmpty && element.elementId == selectedElement.elementId
  }

  private func loadFile(at path: String) async {
    do {
      let content = try await fileService.readFile(at: path, projectPath: projectPath)
      currentFilePath = path
      fileContent = content
      savedFileContent = content
      editorDisplayMode = .displayMode(for: content)
      editorDocumentID = UUID()
      errorMessage = nil
      writeErrorMessage = nil
      recomputeEditingState()
    } catch {
      errorMessage = "Could not load source file: \(error.localizedDescription)"
      currentFilePath = path
      fileContent = ""
      savedFileContent = ""
      trackedTextToken = nil
      trackedTextLocation = nil
      trackedStructuredTextContent = nil
      styleValues = [:]
      activeCapabilities = [.code]
    }
  }

  private func captureElementSnapshot() async {
    guard let selectedElement,
          let previewWebView else {
      selectedElementSnapshot = nil
      return
    }

    do {
      selectedElementSnapshot = try await ElementSnapshotCapture.captureSnapshot(
        of: selectedElement,
        in: previewWebView
      )
    } catch {
      selectedElementSnapshot = nil
    }
  }

  private func recomputeEditingState() {
    guard let selectedElement else {
      activeCapabilities = [.code]
      styleValues = [:]
      trackedTextToken = nil
      trackedTextLocation = nil
      trackedStructuredTextContent = nil
      return
    }

    // Design and content edits are always available — they batch to the
    // session's agent when no direct source mapping is proven.
    var capabilities: Set<WebPreviewEditableCapability> = [.code, .content]
    for property in WebPreviewStyleProperty.allCases {
      capabilities.insert(property.capability)
    }

    matchedSelector = resolution?.matchedSelector
      ?? selectedElement.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

    // A direct text mapping is tracked only when the loaded file is the file
    // being previewed (static preview); otherwise text edits batch to the agent.
    let canTrustContentMatch = userConfirmedLowConfidenceFile || resolution?.isLowConfidence != true
    if isDirectPreviewTarget, canTrustContentMatch {
      if let trackedTextToken,
         let trackedRange = Self.trackedTextRange(
          in: fileContent,
          token: trackedTextToken,
          location: trackedTextLocation
         ) {
        trackedTextLocation = Self.characterOffset(of: trackedRange, in: fileContent)
        trackedStructuredTextContent = nil
      } else if let contentCandidate = selectedElement.textContent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                Self.literalOccurrenceCount(of: contentCandidate, in: fileContent) == 1,
                let range = fileContent.range(of: contentCandidate) {
        trackedTextToken = contentCandidate
        trackedTextLocation = Self.characterOffset(of: range, in: fileContent)
        trackedStructuredTextContent = nil
      } else if let mapping = Self.structuredTextContentMapping(for: selectedElement, in: fileContent) {
        trackedTextToken = mapping.text
        trackedTextLocation = nil
        trackedStructuredTextContent = mapping
        toolbarValues?.textContent = mapping.text
      } else {
        trackedTextToken = nil
        trackedTextLocation = nil
        trackedStructuredTextContent = nil
      }
    } else {
      trackedTextToken = nil
      trackedTextLocation = nil
      trackedStructuredTextContent = nil
    }

    styleValues = [:]
    activeCapabilities = capabilities
  }

  private func scheduleWrite() {
    guard isEditingEnabled else { return }
    pendingWriteTask?.cancel()
    pendingWriteTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: self.writeDebounceDuration)
      guard !Task.isCancelled else { return }
      await self.persistCurrentFileIfNeeded()
    }
  }

  private func recordStyleEdit(propertyName: String, value: String) {
    guard let selectedElement else { return }

    let mappedProperty = WebPreviewStyleProperty(rawValue: propertyName)
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

    if case .direct = styleTiers[propertyName] {
      pendingDirectWrites[propertyName] = trimmedValue
      scheduleDirectWriteFlush()
    } else if trimmedValue.isEmpty {
      pendingEditBatch?.removeStyleChange(property: propertyName)
    } else {
      let oldValue = mappedProperty.map { displayedStyleValue(for: $0) }
      ensurePendingBatch(for: selectedElement)
      pendingEditBatch?.recordStyleChange(
        property: propertyName,
        oldValue: oldValue,
        newValue: trimmedValue
      )
    }

    if let mappedProperty {
      styleValues[mappedProperty] = trimmedValue
      liveProperties = liveProperties?.applyingStyleValue(trimmedValue, for: mappedProperty)
    }

    syncToolbarValue(propertyName: propertyName, value: trimmedValue)
  }

  // MARK: - Tier-1 direct writes

  /// Captures per-property winning-rule provenance for the selected element
  /// and proves file mappings; unprovable properties stay agent-applied.
  private func refreshStyleTiers(for element: ElementInspectorData) {
    provenanceTask?.cancel()
    styleTiers = [:]

    guard isDirectCSSWriteEnabled(),
          let stylesheetContext,
          let previewWebView else {
      return
    }

    let selector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selector.isEmpty else { return }

    let properties = WebPreviewStyleProperty.allCases.map(\.rawValue)
    provenanceTask = Task { [weak self, weak previewWebView] in
      guard let self, let previewWebView else { return }

      let tiers: [String: WebPreviewStyleEditTier]
      switch stylesheetContext {
      case .directFile(let servedFilePath, let contextProjectPath):
        // Static previews: CSSOM cannot read file:// linked stylesheets, but
        // the sources ARE local files — enumerate rules from disk and ask the
        // page only for match verdicts.
        let targets = await self.staticStyleResolver.resolveDirectTargets(
          elementSelector: selector,
          servedFilePath: servedFilePath,
          projectPath: contextProjectPath,
          properties: properties,
          in: previewWebView
        )
        tiers = targets.mapValues { .direct($0) }

      case .devServer:
        guard let provenance = await self.styleProvenanceCapture.captureProvenance(
          selector: selector,
          properties: properties,
          in: previewWebView
        ) else { return }
        guard !Task.isCancelled, self.selectedElement?.id == element.id else { return }

        var resolved: [String: WebPreviewStyleEditTier] = [:]
        var mappingCache: [WebPreviewCSSRuleLocator: StylesheetMappingResult] = [:]

        for winner in provenance.winners where winner.isProvable {
          guard let rule = winner.rule else { continue }
          let result: StylesheetMappingResult
          if let cached = mappingCache[rule] {
            result = cached
          } else {
            result = await self.stylesheetSourceMapper.mapToProvenFile(
              ruleLocator: rule,
              context: stylesheetContext
            )
            mappingCache[rule] = result
          }
          guard !Task.isCancelled else { return }
          if case .proven(let filePath, let contentSHA256) = result {
            resolved[winner.property] = .direct(WebPreviewDirectStyleTarget(
              filePath: filePath,
              ruleIndexPath: rule.ruleIndexPath,
              contentSHA256: contentSHA256
            ))
          }
        }
        tiers = resolved
      }

      guard !Task.isCancelled, self.selectedElement?.id == element.id else { return }
      self.styleTiers = tiers
    }
  }

  /// Reads framework dev-build source metadata for the selected element.
  private func refreshSourceHints(for element: ElementInspectorData) {
    sourceHintTask?.cancel()
    sourceHints = []

    guard let previewWebView else { return }
    let selector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selector.isEmpty else { return }

    sourceHintTask = Task { [weak self, weak previewWebView] in
      guard let self, let previewWebView else { return }
      let hints = await self.sourceHintCapture.captureSourceHints(
        selector: selector,
        in: previewWebView
      )
      guard !Task.isCancelled, self.selectedElement?.id == element.id else { return }
      self.sourceHints = hints
    }
  }

  private func scheduleDirectWriteFlush() {
    pendingDirectWriteTask?.cancel()
    pendingDirectWriteTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: self.writeDebounceDuration)
      guard !Task.isCancelled else { return }
      await self.flushPendingDirectWrites()
    }
  }

  private func flushPendingDirectWrites() async {
    let writes = pendingDirectWrites
    pendingDirectWrites = [:]
    guard !writes.isEmpty else { return }

    isWriting = true
    for (property, value) in writes.sorted(by: { $0.key < $1.key }) {
      guard case .direct(var target) = styleTiers[property] else {
        downgradeToAgentBatch(property: property, value: value)
        continue
      }

      let edit = CSSDeclarationEdit(
        ruleIndexPath: target.ruleIndexPath,
        property: property,
        value: value.isEmpty ? nil : value
      )
      let outcome = await directWriteCoordinator.write(
        edit: edit,
        filePath: target.filePath,
        embeddedStyleBlockIndex: target.embeddedStyleBlockIndex,
        expectedSHA256: target.contentSHA256,
        projectPath: projectPath
      )

      switch outcome {
      case .written(let newSHA256):
        target.contentSHA256 = newSHA256
        styleTiers[property] = .direct(target)
        rebaseDirectTargets(filePath: target.filePath, to: newSHA256, excluding: property)
        await refreshCodeTabAfterDirectWrite(to: target.filePath)
        writeErrorMessage = nil
      case .baselineDrift, .editFailed:
        styleTiers[property] = .agent
        downgradeToAgentBatch(property: property, value: value)
      }
    }
    isWriting = false
  }

  private func rebaseDirectTargets(filePath: String, to newSHA256: String, excluding property: String) {
    for (otherProperty, tier) in styleTiers {
      guard otherProperty != property,
            case .direct(var otherTarget) = tier,
            otherTarget.filePath == filePath else {
        continue
      }
      otherTarget.contentSHA256 = newSHA256
      styleTiers[otherProperty] = .direct(otherTarget)
    }
  }

  /// Keeps the Code tab in sync when a direct write lands in the loaded file.
  private func refreshCodeTabAfterDirectWrite(to filePath: String) async {
    guard currentFilePath == filePath,
          fileContent == savedFileContent,
          let updated = try? await fileService.readFile(at: filePath, projectPath: projectPath) else {
      return
    }
    fileContent = updated
    savedFileContent = updated
    editorDocumentID = UUID()
  }

  private func downgradeToAgentBatch(property: String, value: String) {
    guard let selectedElement, !value.isEmpty else { return }
    ensurePendingBatch(for: selectedElement)
    pendingEditBatch?.recordStyleChange(property: property, oldValue: nil, newValue: value)
  }

  private func recordTextEdit(_ value: String, propagateLiveEdit: Bool) {
    guard let selectedElement else { return }

    if propagateLiveEdit {
      liveEditApplier.apply(
        DesignEdit(element: selectedElement, action: .updateTextContent(value)),
        in: previewWebView
      )
    }

    let oldText = liveProperties?.content
      ?? selectedElement.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
    ensurePendingBatch(for: selectedElement)
    pendingEditBatch?.recordTextChange(oldText: oldText, newText: value)

    liveProperties = liveProperties?.updatingContent(value)
    toolbarValues?.textContent = value
  }

  private func ensurePendingBatch(for element: ElementInspectorData) {
    if pendingEditBatch == nil {
      pendingEditBatch = WebPreviewPendingDesignEditBatch(element: element)
    }
  }

  private func syncToolbarValue(propertyName: String, value: String) {
    switch propertyName {
    case "font-family":
      toolbarValues?.fontFamily = value
    case "color":
      toolbarValues?.color = value
    case "background-color":
      toolbarValues?.backgroundColor = value
    case "font-size":
      toolbarValues?.fontSize = CSSParser.parsePixelValue(value) ?? toolbarValues?.fontSize ?? 16
    case "font-weight":
      toolbarValues?.isBold = CSSParser.isBoldWeight(value)
    case "font-style":
      toolbarValues?.isItalic = value.lowercased() == "italic"
    case "text-align":
      toolbarValues?.textAlign = DesignTextAlignment(rawValue: value.lowercased()) ?? toolbarValues?.textAlign ?? .left
    case "letter-spacing":
      toolbarValues?.letterSpacing = value
    case "line-height":
      toolbarValues?.lineHeight = value
    case "border-radius":
      toolbarValues?.borderRadius = value
    case "padding":
      toolbarValues?.padding = value
    case "margin":
      toolbarValues?.margin = value
    case "object-fit":
      toolbarValues?.objectFit = value
    default:
      break
    }
  }

  private func persistCurrentFileIfNeeded() async {
    guard isEditingEnabled,
          let currentFilePath,
          fileContent != savedFileContent else {
      return
    }

    isWriting = true
    writeErrorMessage = nil
    let contentToWrite = fileContent

    do {
      try await fileService.writeFile(at: currentFilePath, content: contentToWrite, projectPath: projectPath)
      savedFileContent = contentToWrite
    } catch {
      writeErrorMessage = "Update failed: \(error.localizedDescription)"
    }

    isWriting = false
  }

  private static func structuredTextContentMapping(
    for element: ElementInspectorData,
    in content: String,
    expectedText: String? = nil
  ) -> SourceTextContentMapping? {
    let category = ElementCategory(tagName: element.tagName)
    guard category == .text || category == .button else {
      return nil
    }

    let expected = (expectedText ?? element.textContent.trimmingCharacters(in: .whitespacesAndNewlines))
    guard expectedText != nil || !expected.isEmpty else {
      return nil
    }

    let innerRanges = htmlElementInnerRanges(for: element, in: content)
    let matches = innerRanges.compactMap { innerRange -> SourceTextContentMapping? in
      guard let mapping = sourceTextContentMapping(in: innerRange, content: content),
            mapping.text == expected else {
        return nil
      }
      return mapping
    }

    return matches.count == 1 ? matches[0] : nil
  }

  private static func updateStructuredTextContent(
    _ mapping: SourceTextContentMapping,
    in content: String,
    to newText: String,
    element: ElementInspectorData
  ) -> (content: String, mapping: SourceTextContentMapping)? {
    guard let splice = textSplice(from: mapping.text, to: newText) else {
      return (content, mapping)
    }

    guard !mapping.segments.isEmpty else {
      return nil
    }

    var segmentTexts = mapping.segments.map(\.text)
    if splice.start == mapping.text.count {
      let targetIndex = mapping.text.isEmpty ? 0 : segmentTexts.count - 1
      segmentTexts[targetIndex] += splice.replacement
    } else {
      var inserted = false
      for index in mapping.segments.indices {
        let segment = mapping.segments[index]
        if segment.textEnd < splice.start || segment.textStart > splice.end {
          continue
        }

        let localStart = max(0, splice.start - segment.textStart)
        let localEnd = min(segment.text.count, splice.end - segment.textStart)
        if !inserted {
          segmentTexts[index] = prefix(segment.text, count: localStart)
            + splice.replacement
            + suffix(segment.text, droppingFirst: localEnd)
          inserted = true
        } else {
          segmentTexts[index] = suffix(segment.text, droppingFirst: localEnd)
        }
      }

      if !inserted {
        segmentTexts[segmentTexts.count - 1] += splice.replacement
      }
    }

    var updatedContent = content
    for index in mapping.segments.indices.reversed() {
      updatedContent.replaceSubrange(
        mapping.segments[index].rawRange,
        with: escapeHTMLText(segmentTexts[index])
      )
    }

    guard let updatedMapping = structuredTextContentMapping(
      for: element,
      in: updatedContent,
      expectedText: newText
    ) else {
      return nil
    }

    return (updatedContent, updatedMapping)
  }

  private static func textSplice(from oldText: String, to newText: String) -> TextSplice? {
    guard oldText != newText else {
      return nil
    }

    let oldCharacters = Array(oldText)
    let newCharacters = Array(newText)
    var prefixCount = 0
    let maxPrefixCount = min(oldCharacters.count, newCharacters.count)
    while prefixCount < maxPrefixCount,
          oldCharacters[prefixCount] == newCharacters[prefixCount] {
      prefixCount += 1
    }

    var oldSuffixIndex = oldCharacters.count
    var newSuffixIndex = newCharacters.count
    while oldSuffixIndex > prefixCount,
          newSuffixIndex > prefixCount,
          oldCharacters[oldSuffixIndex - 1] == newCharacters[newSuffixIndex - 1] {
      oldSuffixIndex -= 1
      newSuffixIndex -= 1
    }

    return TextSplice(
      start: prefixCount,
      end: oldSuffixIndex,
      replacement: String(newCharacters[prefixCount..<newSuffixIndex])
    )
  }

  private static func sourceTextContentMapping(
    in innerRange: Range<String.Index>,
    content: String
  ) -> SourceTextContentMapping? {
    var segments: [SourceTextSegment] = []
    var textOffset = 0
    var cursor = innerRange.lowerBound

    func appendSegment(_ range: Range<String.Index>) {
      guard !range.isEmpty else { return }
      let rawText = String(content[range])
      let text = decodeHTMLText(rawText)
      guard !text.isEmpty else { return }
      segments.append(SourceTextSegment(rawRange: range, text: text, textStart: textOffset))
      textOffset += text.count
    }

    while cursor < innerRange.upperBound {
      guard let tagStart = content.range(of: "<", range: cursor..<innerRange.upperBound)?.lowerBound else {
        appendSegment(cursor..<innerRange.upperBound)
        break
      }

      appendSegment(cursor..<tagStart)

      guard let tagEnd = htmlTagEnd(startingAt: tagStart, in: content),
            tagEnd < innerRange.upperBound else {
        return nil
      }
      cursor = content.index(after: tagEnd)
    }

    guard !segments.isEmpty else {
      return nil
    }

    return SourceTextContentMapping(
      text: segments.map(\.text).joined(),
      segments: segments
    )
  }

  private static func htmlElementInnerRanges(
    for element: ElementInspectorData,
    in content: String
  ) -> [Range<String.Index>] {
    let tagName = element.tagName.lowercased()
    guard !tagName.isEmpty else {
      return []
    }

    var ranges: [Range<String.Index>] = []
    var cursor = content.startIndex
    while let start = htmlStartTagStart(tagName: tagName, in: content, range: cursor..<content.endIndex) {
      guard let startTagEnd = htmlTagEnd(startingAt: start, in: content) else {
        break
      }

      let startTag = String(content[start...startTagEnd])
      if htmlStartTag(startTag, matches: element),
         let closeStart = htmlClosingTagStart(
          tagName: tagName,
          afterOpeningTagEndingAt: startTagEnd,
          in: content
         ) {
        ranges.append(content.index(after: startTagEnd)..<closeStart)
      }

      cursor = content.index(after: start)
    }

    return ranges
  }

  private static func htmlStartTag(
    _ startTag: String,
    matches element: ElementInspectorData
  ) -> Bool {
    if !element.elementId.isEmpty {
      guard htmlAttribute("id", in: startTag) == element.elementId else {
        return false
      }
    }

    let classNames = element.className
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .filter { !$0.isEmpty }
    if !classNames.isEmpty {
      let sourceClasses = Set(
        (htmlAttribute("class", in: startTag) ?? "")
          .split(whereSeparator: \.isWhitespace)
          .map(String.init)
      )
      guard classNames.allSatisfy(sourceClasses.contains) else {
        return false
      }
    }

    return true
  }

  private static func htmlAttribute(_ name: String, in startTag: String) -> String? {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    let pattern = #"\b"# + escapedName + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }

    let range = NSRange(startTag.startIndex..<startTag.endIndex, in: startTag)
    guard let match = regex.firstMatch(in: startTag, range: range),
          let valueRange = Range(match.range(at: 1), in: startTag) else {
      return nil
    }

    var value = String(startTag[valueRange])
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
      value.removeFirst()
      value.removeLast()
    }
    return decodeHTMLText(value)
  }

  private static func htmlStartTagStart(
    tagName: String,
    in content: String,
    range: Range<String.Index>
  ) -> String.Index? {
    var cursor = range.lowerBound
    let needle = "<\(tagName)"
    while cursor < range.upperBound,
          let found = content.range(of: needle, options: [.caseInsensitive], range: cursor..<range.upperBound) {
      let afterTagName = found.upperBound
      if afterTagName == content.endIndex || isHTMLTagNameBoundary(content[afterTagName]) {
        return found.lowerBound
      }
      cursor = afterTagName
    }
    return nil
  }

  private static func htmlClosingTagStart(
    tagName: String,
    afterOpeningTagEndingAt openingTagEnd: String.Index,
    in content: String
  ) -> String.Index? {
    var depth = 1
    var cursor = content.index(after: openingTagEnd)

    while cursor < content.endIndex {
      let searchRange = cursor..<content.endIndex
      let nextOpening = htmlStartTagStart(tagName: tagName, in: content, range: searchRange)
      let nextClosing = htmlClosingTagStart(tagName: tagName, in: content, range: searchRange)

      guard let nearest = nearestHTMLTag(opening: nextOpening, closing: nextClosing) else {
        return nil
      }

      switch nearest.kind {
      case .opening:
        guard let tagEnd = htmlTagEnd(startingAt: nearest.index, in: content) else {
          return nil
        }
        if !isSelfClosingHTMLTag(content[nearest.index...tagEnd]) {
          depth += 1
        }
        cursor = content.index(after: tagEnd)
      case .closing:
        depth -= 1
        if depth == 0 {
          return nearest.index
        }
        guard let tagEnd = htmlTagEnd(startingAt: nearest.index, in: content) else {
          return nil
        }
        cursor = content.index(after: tagEnd)
      }
    }

    return nil
  }

  private enum HTMLTagKind {
    case opening
    case closing
  }

  private static func nearestHTMLTag(
    opening: String.Index?,
    closing: String.Index?
  ) -> (kind: HTMLTagKind, index: String.Index)? {
    switch (opening, closing) {
    case (.some(let opening), .some(let closing)):
      if opening < closing {
        return (kind: .opening, index: opening)
      }
      return (kind: .closing, index: closing)
    case (.some(let opening), nil):
      return (kind: .opening, index: opening)
    case (nil, .some(let closing)):
      return (kind: .closing, index: closing)
    case (nil, nil):
      return nil
    }
  }

  private static func htmlClosingTagStart(
    tagName: String,
    in content: String,
    range: Range<String.Index>
  ) -> String.Index? {
    var cursor = range.lowerBound
    let needle = "</\(tagName)"
    while cursor < range.upperBound,
          let found = content.range(of: needle, options: [.caseInsensitive], range: cursor..<range.upperBound) {
      let afterTagName = found.upperBound
      if afterTagName == content.endIndex || isHTMLTagNameBoundary(content[afterTagName]) {
        return found.lowerBound
      }
      cursor = afterTagName
    }
    return nil
  }

  private static func htmlTagEnd(startingAt start: String.Index, in content: String) -> String.Index? {
    var cursor = start
    var quote: Character?

    while cursor < content.endIndex {
      let character = content[cursor]
      if let activeQuote = quote {
        if character == activeQuote {
          quote = nil
        }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == ">" {
        return cursor
      }
      cursor = content.index(after: cursor)
    }

    return nil
  }

  private static func isSelfClosingHTMLTag(_ tag: Substring) -> Bool {
    String(tag.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
  }

  private static func isHTMLTagNameBoundary(_ character: Character) -> Bool {
    character == ">" || character == "/" || character.isWhitespace
  }

  private static func decodeHTMLText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private static func escapeHTMLText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static func prefix(_ text: String, count: Int) -> String {
    String(text.prefix(max(0, count)))
  }

  private static func suffix(_ text: String, droppingFirst count: Int) -> String {
    String(text.dropFirst(max(0, count)))
  }

  private static func trackedTextRange(
    in content: String,
    token: String,
    location: Int?
  ) -> Range<String.Index>? {
    if let location,
       let startIndex = index(in: content, atCharacterOffset: location) {
      if token.isEmpty {
        return startIndex..<startIndex
      }

      if let endIndex = content.index(startIndex, offsetBy: token.count, limitedBy: content.endIndex) {
        let range = startIndex..<endIndex
        if String(content[range]) == token {
          return range
        }
      }
    }

    guard !token.isEmpty,
          literalOccurrenceCount(of: token, in: content) == 1 else {
      return nil
    }
    return content.range(of: token)
  }

  private static func index(in content: String, atCharacterOffset offset: Int) -> String.Index? {
    guard offset >= 0, offset <= content.count else {
      return nil
    }
    return content.index(content.startIndex, offsetBy: offset, limitedBy: content.endIndex)
  }

  private static func characterOffset(of range: Range<String.Index>, in content: String) -> Int {
    content.distance(from: content.startIndex, to: range.lowerBound)
  }

  private static func literalOccurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var start = haystack.startIndex
    while start < haystack.endIndex,
          let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
      count += 1
      start = range.upperBound
    }
    return count
  }

  private func preferredUnit(for property: WebPreviewStyleProperty) -> String? {
    Self.numericComponents(from: displayedStyleValue(for: property))?.unit ?? property.fallbackUnit
  }

  private func resolvedColorValue(for property: WebPreviewStyleProperty) -> String {
    let currentValue = displayedStyleValue(for: property).trimmingCharacters(in: .whitespacesAndNewlines)
    if !currentValue.isEmpty {
      return currentValue
    }

    return liveProperties?.value(for: property)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func numericComponents(from value: String) -> (number: String, unit: String)? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let unitStart = trimmed.firstIndex(where: { $0.isLetter || $0 == "%" }) else {
      return nil
    }

    let number = trimmed[..<unitStart].trimmingCharacters(in: .whitespacesAndNewlines)
    let unit = trimmed[unitStart...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard isPlainNumericValue(number),
          !unit.isEmpty,
          unit.allSatisfy({ $0.isLetter || $0 == "%" }) else {
      return nil
    }

    return (number: number, unit: String(unit))
  }

  private static func isPlainNumericValue(_ value: String) -> Bool {
    value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil
  }

  private static func stripUnit(_ unit: String, from value: String) -> String? {
    guard let components = numericComponents(from: value),
          components.unit.compare(unit, options: .caseInsensitive) == .orderedSame else {
      return nil
    }
    return components.number
  }

  private static func parseColor(from value: String) -> NSColor? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.caseInsensitiveCompare("transparent") == .orderedSame {
      return .clear
    }

    if let hexColor = parseHexColor(from: trimmed) {
      return hexColor
    }

    return parseRGBColor(from: trimmed)
  }

  private static func parseHexColor(from value: String) -> NSColor? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else { return nil }

    let rawHex = String(trimmed.dropFirst())
    let expandedHex: String
    switch rawHex.count {
    case 3, 4:
      expandedHex = rawHex.map { "\($0)\($0)" }.joined()
    case 6, 8:
      expandedHex = rawHex
    default:
      return nil
    }

    guard let hexValue = UInt64(expandedHex, radix: 16) else { return nil }

    let r, g, b, a: UInt64
    switch expandedHex.count {
    case 6:
      (r, g, b, a) = (
        (hexValue >> 16) & 0xFF,
        (hexValue >> 8) & 0xFF,
        hexValue & 0xFF,
        0xFF
      )
    case 8:
      (r, g, b, a) = (
        (hexValue >> 24) & 0xFF,
        (hexValue >> 16) & 0xFF,
        (hexValue >> 8) & 0xFF,
        hexValue & 0xFF
      )
    default:
      return nil
    }

    return NSColor(
      srgbRed: CGFloat(r) / 255.0,
      green: CGFloat(g) / 255.0,
      blue: CGFloat(b) / 255.0,
      alpha: CGFloat(a) / 255.0
    )
  }

  private static func parseRGBColor(from value: String) -> NSColor? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()
    guard lowercased.hasPrefix("rgb(") || lowercased.hasPrefix("rgba("),
          let openParen = trimmed.firstIndex(of: "("),
          let closeParen = trimmed.lastIndex(of: ")"),
          openParen < closeParen else {
      return nil
    }

    let rawComponents = trimmed[trimmed.index(after: openParen)..<closeParen]
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard rawComponents.count == 3 || rawComponents.count == 4,
          let red = Double(rawComponents[0]),
          let green = Double(rawComponents[1]),
          let blue = Double(rawComponents[2]) else {
      return nil
    }

    let alpha = rawComponents.count == 4 ? Double(rawComponents[3]) ?? 1.0 : 1.0
    return NSColor(
      srgbRed: CGFloat(max(0, min(255, red))) / 255.0,
      green: CGFloat(max(0, min(255, green))) / 255.0,
      blue: CGFloat(max(0, min(255, blue))) / 255.0,
      alpha: CGFloat(max(0, min(1, alpha)))
    )
  }

  private static func serializedColor(from color: NSColor) -> String {
    let resolvedColor = color.usingColorSpace(.sRGB) ?? color
    let red = Int(round(resolvedColor.redComponent * 255))
    let green = Int(round(resolvedColor.greenComponent * 255))
    let blue = Int(round(resolvedColor.blueComponent * 255))
    let alpha = resolvedColor.alphaComponent

    if alpha < 0.999 {
      return String(format: "rgba(%d, %d, %d, %.2f)", red, green, blue, alpha)
    }

    return Color.hexString(from: resolvedColor)
  }

}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
