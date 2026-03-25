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

@MainActor
@Observable
final class WebPreviewInspectorViewModel {
  let sessionID: String
  let projectPath: String

  private let sourceResolver: any WebPreviewSourceResolverProtocol
  private let fileService: any ProjectFileServiceProtocol
  private let writeDebounceDuration: Duration

  private var pendingWriteTask: Task<Void, Never>?
  private var trackedTextToken: String?
  private var userConfirmedLowConfidenceFile = false

  private(set) var selectedElement: ElementInspectorData?
  private(set) var resolution: WebPreviewSourceResolution?
  private(set) var liveProperties: WebPreviewLivePropertiesSnapshot?

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
    writeDebounceDuration: Duration = .milliseconds(600)
  ) {
    self.sessionID = sessionID
    self.projectPath = projectPath
    self.sourceResolver = sourceResolver
    self.fileService = fileService
    self.writeDebounceDuration = writeDebounceDuration
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
    isEditingEnabled && !editableStyleProperties.isEmpty
  }

  var canEditContent: Bool {
    isEditingEnabled && activeCapabilities.contains(.content)
  }

  var editableStyleProperties: [WebPreviewStyleProperty] {
    WebPreviewStyleProperty.allCases.filter { activeCapabilities.contains($0.capability) }
  }

  var hasEditableDesignControls: Bool {
    canEditContent || isDesignValueEditingEnabled
  }

  var designTabMessage: String? {
    if needsSourceConfirmation {
      return "Choose a source file in Code mode to enable design edits."
    }
    if !hasEditableDesignControls {
      return "This element does not have a safe design mapping. Edit it in Code mode."
    }
    return nil
  }

  var selectedTagName: String? {
    selectedElement?.tagName.lowercased().nilIfEmpty
  }

  var selectorSummary: String? {
    matchedSelector ?? selectedElement?.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  var confidenceDisplayText: String {
    resolution?.confidence.displayName ?? "No source match"
  }

  var contentDisplayText: String {
    liveProperties?.content ?? "—"
  }

  var relativeFilePath: String? {
    guard let currentFilePath else { return nil }
    return displayPath(for: currentFilePath)
  }

  var hasUnsavedChanges: Bool {
    fileContent != savedFileContent
  }

  var saveStatusText: String {
    if needsSourceConfirmation {
      return "Choose a source file to enable editing"
    }
    if let writeErrorMessage {
      return writeErrorMessage
    }
    if isResolving {
      return "Mapping source…"
    }
    if isWriting {
      return "Updating file…"
    }
    if hasUnsavedChanges {
      return "Pending update"
    }
    return (isDesignValueEditingEnabled || canEditContent) ? "Live design sync on" : "Code editing available"
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

  func inspect(
    element: ElementInspectorData,
    previewFilePath: String?,
    recentActivities: [ActivityEntry]
  ) async {
    await flushPendingWriteIfNeeded()

    selectedElement = element
    liveProperties = WebPreviewLivePropertiesSnapshot(element: element)
    isPanelVisible = true
    isResolving = true
    errorMessage = nil
    writeErrorMessage = nil
    resolution = nil
    currentFilePath = nil
    fileContent = ""
    savedFileContent = ""
    editorDocumentID = UUID()
    trackedTextToken = nil
    matchedSelector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    styleValues = [:]
    activeCapabilities = [.code]
    userConfirmedLowConfidenceFile = false

    let resolved = await sourceResolver.resolveSource(
      for: element,
      projectPath: projectPath,
      previewFilePath: previewFilePath,
      recentActivities: recentActivities
    )

    resolution = resolved
    matchedSelector = resolved.matchedSelector ?? matchedSelector

    let startingFilePath = resolved.primaryFilePath ?? resolved.candidateFilePaths.first
    guard let startingFilePath else {
      errorMessage = "No editable source files were found for this element."
      isResolving = false
      return
    }

    if resolved.isLowConfidence {
      isResolving = false
      return
    }

    await loadFile(at: startingFilePath)
    isResolving = false
  }

  func closePanel() async {
    await flushPendingWriteIfNeeded()
    isPanelVisible = false
    isResolving = false
    isWriting = false
    errorMessage = nil
    writeErrorMessage = nil
    selectedElement = nil
    resolution = nil
    liveProperties = nil
    currentFilePath = nil
    fileContent = ""
    savedFileContent = ""
    editorDocumentID = UUID()
    activeCapabilities = [.code]
    trackedTextToken = nil
    matchedSelector = nil
    styleValues = [:]
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
    guard canEditContent,
          let previousTextToken = trackedTextToken,
          !previousTextToken.isEmpty,
          let updatedContent = Self.replaceUniqueOccurrence(
            in: fileContent,
            from: previousTextToken,
            to: value
          ) else {
      return
    }

    trackedTextToken = value
    fileContent = updatedContent
    liveProperties = liveProperties.map {
      WebPreviewLivePropertiesSnapshot(
        width: $0.width,
        height: $0.height,
        top: $0.top,
        left: $0.left,
        content: value,
        fontFamily: $0.fontFamily,
        fontWeight: $0.fontWeight,
        fontSize: $0.fontSize,
        lineHeight: $0.lineHeight,
        textColor: $0.textColor,
        backgroundColor: $0.backgroundColor
      )
    }
    scheduleWrite()
  }

  func updateStyleValue(_ property: WebPreviewStyleProperty, value: String) {
    guard isEditable(property),
          let selector = matchedSelector,
          let updatedContent = Self.updateCSSDeclaration(
            in: fileContent,
            selectorCandidates: [selector],
            property: property.rawValue,
            value: value
          ) else {
      return
    }

    styleValues[property] = value
    liveProperties = liveProperties?.applyingStyleValue(value, for: property)
    fileContent = updatedContent
    scheduleWrite()
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
    await persistCurrentFileIfNeeded()
  }

  // MARK: - Private

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
      styleValues = [:]
      activeCapabilities = [.code]
    }
  }

  private func recomputeEditingState() {
    guard let selectedElement else {
      activeCapabilities = [.code]
      styleValues = [:]
      return
    }

    var capabilities: Set<WebPreviewEditableCapability> = [.code]
    var nextStyleValues: [WebPreviewStyleProperty: String] = [:]
    matchedSelector = resolution?.matchedSelector
      ?? selectedElement.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

    guard currentFilePath != nil else {
      activeCapabilities = capabilities
      trackedTextToken = nil
      styleValues = nextStyleValues
      return
    }

    if let contentCandidate = trackedTextToken ?? selectedElement.textContent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
       Self.literalOccurrenceCount(of: contentCandidate, in: fileContent) == 1,
       userConfirmedLowConfidenceFile || resolution?.isLowConfidence != true {
      capabilities.insert(.content)
      trackedTextToken = contentCandidate
    } else {
      trackedTextToken = nil
    }

    let mayEnableInlineEditing =
      (resolution?.matchedSelector != nil && resolution?.confidence != .low) || userConfirmedLowConfidenceFile

    if mayEnableInlineEditing,
       let selector = Self.firstMatchingSelector(
        candidates: Self.selectorCandidates(for: selectedElement, fallback: matchedSelector),
        in: fileContent
       ),
       Self.cssBodyRange(for: [selector], in: fileContent) != nil {
      matchedSelector = selector
      for property in WebPreviewStyleProperty.allCases {
        capabilities.insert(property.capability)
        nextStyleValues[property] = Self.currentCSSDeclaration(
          in: fileContent,
          selectorCandidates: [selector],
          property: property.rawValue
        ) ?? liveProperties?.value(for: property) ?? ""
      }
    }

    styleValues = nextStyleValues
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

  private static func selectorCandidates(for element: ElementInspectorData, fallback: String?) -> [String] {
    let classes = element.className
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .filter { !$0.isEmpty }

    return LinkedHashSet(elements:
      [fallback].compactMap { $0 }
        + (element.elementId.isEmpty ? [] : ["#\(element.elementId)"])
        + classes.map { ".\($0)" }
        + [element.tagName.lowercased()]
    ).elements
  }

  private static func replaceUniqueOccurrence(in content: String, from oldValue: String, to newValue: String) -> String? {
    guard literalOccurrenceCount(of: oldValue, in: content) == 1,
          let range = content.range(of: oldValue) else {
      return nil
    }
    return content.replacingCharacters(in: range, with: newValue)
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

  private static func firstMatchingSelector(candidates: [String], in content: String) -> String? {
    for candidate in candidates where !candidate.isEmpty {
      if content.range(of: candidate) != nil {
        return candidate
      }
    }
    return nil
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

  private static func currentCSSDeclaration(
    in content: String,
    selectorCandidates: [String],
    property: String
  ) -> String? {
    guard let body = cssBody(for: selectorCandidates, in: content) else { return nil }
    let lines = body.components(separatedBy: .newlines)
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix("\(property):") || trimmed.hasPrefix("\(property) :") else { continue }
      return trimmed
        .components(separatedBy: ":")
        .dropFirst()
        .joined(separator: ":")
        .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
    }
    return nil
  }

  private static func updateCSSDeclaration(
    in content: String,
    selectorCandidates: [String],
    property: String,
    value: String
  ) -> String? {
    guard let bodyRange = cssBodyRange(for: selectorCandidates, in: content) else { return nil }

    let body = String(content[bodyRange])
    let lines = body.components(separatedBy: .newlines)
    var updatedLines: [String] = []
    var replaced = false

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("\(property):") || trimmed.hasPrefix("\(property) :") {
        replaced = true
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
          updatedLines.append("\(indentation)\(property): \(value);")
        }
      } else {
        updatedLines.append(line)
      }
    }

    if !replaced, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let insertLine = "  \(property): \(value);"
      if updatedLines.isEmpty {
        updatedLines = [insertLine]
      } else {
        updatedLines.append(insertLine)
      }
    }

    let updatedBody = updatedLines.joined(separator: "\n")
    var newContent = content
    newContent.replaceSubrange(bodyRange, with: updatedBody)
    return newContent
  }

  private static func cssBody(for selectorCandidates: [String], in content: String) -> String? {
    guard let range = cssBodyRange(for: selectorCandidates, in: content) else { return nil }
    return String(content[range])
  }

  private static func cssBodyRange(for selectorCandidates: [String], in content: String) -> Range<String.Index>? {
    for selector in selectorCandidates where !selector.isEmpty {
      guard let selectorRange = content.range(of: selector),
            let braceStart = content[selectorRange.upperBound...].firstIndex(of: "{") else {
        continue
      }

      var depth = 1
      var cursor = content.index(after: braceStart)
      while cursor < content.endIndex {
        let character = content[cursor]
        if character == "{" {
          depth += 1
        } else if character == "}" {
          depth -= 1
          if depth == 0 {
            return content.index(after: braceStart)..<cursor
          }
        }
        cursor = content.index(after: cursor)
      }
    }

    return nil
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

private struct LinkedHashSet<Element: Hashable> {
  let elements: [Element]

  init(elements: [Element]) {
    var seen: Set<Element> = []
    self.elements = elements.filter { seen.insert($0).inserted }
  }
}
