//
//  SourceCodeEditorView.swift
//  AgentHub
//
//  Shared source editor used by the file explorer and web preview inspector rail.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

// MARK: - EditorDisplayMode

enum EditorDisplayMode: Equatable {
  case highlighted
  case plainText

  private static let highlightedByteLimit = 300_000
  private static let highlightedLineLimit = 5_000
  private static let highlightedMaxLineByteLimit = 2_000

  var badgeLabel: String? {
    switch self {
    case .highlighted:
      nil
    case .plainText:
      "Fast Mode"
    }
  }

  var highlightsSyntax: Bool {
    self == .highlighted
  }

  var usesFullEditorFeatures: Bool {
    self == .highlighted
  }

  static func displayMode(for content: String) -> EditorDisplayMode {
    displayMode(for: TextFileMetrics.metrics(for: content))
  }

  static func displayMode(for metrics: TextFileMetrics) -> EditorDisplayMode {
    if metrics.byteCount <= highlightedByteLimit,
       metrics.lineCount <= highlightedLineLimit,
       metrics.maxLineByteCount <= highlightedMaxLineByteLimit {
      return .highlighted
    }
    return .plainText
  }
}

// MARK: - SourceCodeEditorView

struct SourceCodeEditorView: View {
  @Binding var text: String
  let fileName: String
  let documentID: UUID
  let displayMode: EditorDisplayMode
  var isEditable = true
  let onTextChange: (String) -> Void
  let onIdleTextSnapshot: (String) -> Void

  var body: some View {
    SourceCodeEditorHost(
      text: $text,
      fileName: fileName,
      displayMode: displayMode,
      isEditable: isEditable,
      onTextChange: onTextChange,
      onIdleTextSnapshot: onIdleTextSnapshot
    )
    .clipped()
    .id(documentID)
  }
}

// MARK: - SourceCodeEditorHost

private struct SourceCodeEditorHost: View {
  @Binding var text: String
  let fileName: String
  let displayMode: EditorDisplayMode
  let isEditable: Bool
  let onTextChange: (String) -> Void
  let onIdleTextSnapshot: (String) -> Void

  @AppStorage(AgentHubDefaults.sourceEditorMinimapEnabled)
  private var sourceEditorMinimapEnabled: Bool = true
  @AppStorage(AgentHubDefaults.sourceEditorWrapLinesEnabled)
  private var sourceEditorWrapLinesEnabled: Bool = true
  @Environment(\.colorScheme) private var colorScheme
  @State private var editorState = SourceEditorState()
  @State private var editCoordinator = SourceEditorEditCoordinator()

  var body: some View {
    SourceEditor(
      $text,
      language: SourceEditorLanguageResolver.language(
        forFileName: fileName,
        content: text,
        displayMode: displayMode
      ),
      configuration: editorOptions.makeSourceEditorConfiguration(colorScheme: colorScheme),
      state: $editorState,
      highlightProviders: highlightProviders,
      coordinators: [editCoordinator]
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      editCoordinator.configure(
        onTextChange: onTextChange,
        onIdleTextSnapshot: onIdleTextSnapshot
      )
      editCoordinator.repairFindPanelHitTesting()
      editCoordinator.updateFindNavigation(
        text: editorState.findText,
        isPanelVisible: editorState.findPanelVisible == true
      )
      editCoordinator.syncExternalText(text)
    }
    .onChange(of: text) { _, newText in
      editCoordinator.syncExternalText(newText)
    }
    .onChange(of: editorState.findText) { _, newText in
      editCoordinator.updateFindNavigation(
        text: newText,
        isPanelVisible: editorState.findPanelVisible == true
      )
    }
    .onChange(of: editorState.findPanelVisible) { _, isVisible in
      editCoordinator.updateFindNavigation(
        text: editorState.findText,
        isPanelVisible: isVisible == true
      )
    }
  }

  private var editorOptions: AgentHubSourceEditorOptions {
    AgentHubSourceEditorOptions(
      displayMode: displayMode,
      isEditable: isEditable,
      isMinimapEnabled: sourceEditorMinimapEnabled,
      isWrapLinesEnabled: sourceEditorWrapLinesEnabled
    )
  }

  private var highlightProviders: [any HighlightProviding]? {
    displayMode.highlightsSyntax ? nil : []
  }
}

// MARK: - AgentHubSourceEditorOptions

struct AgentHubSourceEditorOptions {
  let displayMode: EditorDisplayMode
  let isEditable: Bool
  let isMinimapEnabled: Bool
  let isWrapLinesEnabled: Bool

  let lineHeightMultiple: Double = 1.3
  // CodeEdit treats 1.0 as neutral spacing. Passing 0 applies a full negative
  // character-width kern and collapses line measurement.
  let letterSpacing: Double = 1.0
  let tabWidth = 2
  let editorOverscroll: CGFloat = 0.2
  let additionalTextInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

  var wrapLines: Bool {
    isWrapLinesEnabled && displayMode.usesFullEditorFeatures
  }

  var bracketPairEmphasis: BracketPairEmphasis? {
    displayMode.highlightsSyntax ? .flash : nil
  }

  var showMinimap: Bool {
    isMinimapEnabled && displayMode.usesFullEditorFeatures
  }

  var showFoldingRibbon: Bool {
    displayMode.usesFullEditorFeatures
  }

  func makeSourceEditorConfiguration(colorScheme: ColorScheme) -> SourceEditorConfiguration {
    SourceEditorConfiguration(
      appearance: .init(
        theme: AgentHubSourceEditorTheme.theme(for: colorScheme),
        useThemeBackground: true,
        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
        lineHeightMultiple: lineHeightMultiple,
        letterSpacing: letterSpacing,
        wrapLines: wrapLines,
        useSystemCursor: true,
        tabWidth: tabWidth,
        bracketPairEmphasis: bracketPairEmphasis
      ),
      behavior: .init(
        isEditable: isEditable,
        isSelectable: true,
        indentOption: .spaces(count: 2),
        reformatAtColumn: 100
      ),
      layout: .init(
        editorOverscroll: editorOverscroll,
        contentInsets: nil,
        additionalTextInsets: additionalTextInsets
      ),
      peripherals: .init(
        showGutter: true,
        showMinimap: showMinimap,
        showReformattingGuide: false,
        showFoldingRibbon: showFoldingRibbon
      )
    )
  }
}

// MARK: - SourceEditorEditCoordinator

private final class SourceEditorEditCoordinator: TextViewCoordinator {
  private weak var controller: TextViewController?
  private var isApplyingExternalText = false
  private var shouldSkipNextExternalTextSync = false
  private var idleTask: Task<Void, Never>?
  private var findNavigationEventMonitor: Any?
  private var findNavigationText = ""
  private var isFindPanelVisible = false
  private var isUsingFindPanelNavigation = false
  private var lastFindNavigationRange: NSRange?
  private var onTextChange: (String) -> Void = { _ in }
  private var onIdleTextSnapshot: (String) -> Void = { _ in }

  func configure(
    onTextChange: @escaping (String) -> Void,
    onIdleTextSnapshot: @escaping (String) -> Void
  ) {
    self.onTextChange = onTextChange
    self.onIdleTextSnapshot = onIdleTextSnapshot
  }

  func prepareCoordinator(controller: TextViewController) {
    self.controller = controller
    installFindNavigationEventMonitor()
  }

  func controllerDidAppear(controller: TextViewController) {
    SourceEditorFindPanelHitTestingFix.apply(to: controller)
  }

  func repairFindPanelHitTesting() {
    guard let controller else { return }
    SourceEditorFindPanelHitTestingFix.apply(to: controller)
  }

  func updateFindNavigation(text: String?, isPanelVisible: Bool) {
    let nextText = text ?? ""
    if nextText != findNavigationText {
      lastFindNavigationRange = nil
    }
    findNavigationText = nextText
    self.isFindPanelVisible = isPanelVisible
    if isPanelVisible, !nextText.isEmpty {
      isUsingFindPanelNavigation = true
    } else if !isPanelVisible {
      isUsingFindPanelNavigation = false
    }
  }

  func textViewDidChangeText(controller: TextViewController) {
    guard !isApplyingExternalText else { return }
    let updatedText = controller.text
    shouldSkipNextExternalTextSync = true
    onTextChange(updatedText)
    scheduleIdleSnapshot(updatedText)
  }

  func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
    guard let range = newPositions.first?.range else { return }
    lastFindNavigationRange = range
    syncFindNavigationTextFromPanel(in: controller)
    guard shouldHandleFindNavigation(in: controller) else { return }
    guard isFindMatchRange(range, in: controller) else { return }
    scrollFindMatch(range, in: controller)
  }

  func syncExternalText(_ text: String) {
    guard let controller else { return }
    if shouldSkipNextExternalTextSync {
      shouldSkipNextExternalTextSync = false
      return
    }
    guard controller.text != text else { return }
    isApplyingExternalText = true
    controller.text = text
    isApplyingExternalText = false
  }

  func destroy() {
    idleTask?.cancel()
    if let findNavigationEventMonitor {
      NSEvent.removeMonitor(findNavigationEventMonitor)
      self.findNavigationEventMonitor = nil
    }
  }

  private func scheduleIdleSnapshot(_ text: String) {
    idleTask?.cancel()
    idleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled else { return }
      self?.onIdleTextSnapshot(text)
    }
  }

  private func installFindNavigationEventMonitor() {
    guard findNavigationEventMonitor == nil else { return }
    findNavigationEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .leftMouseDown, .leftMouseUp]
    ) { [weak self] event in
      self?.handleFindNavigationEvent(event) ?? event
    }
  }

  private func handleFindNavigationEvent(_ event: NSEvent) -> NSEvent? {
    guard let controller,
          controller.view.window?.isKeyWindow == true,
          shouldHandleFindNavigation(in: controller) else {
      return event
    }

    syncFindNavigationTextFromPanel(in: controller)
    guard !findNavigationText.isEmpty else { return event }

    switch event.type {
    case .keyDown:
      return handleFindNavigationKeyDown(event, controller: controller)
    case .leftMouseDown:
      return handleFindNavigationMouseDown(event, controller: controller)
    case .leftMouseUp:
      return handleFindNavigationMouseUp(event, controller: controller)
    default:
      return event
    }
  }

  private func handleFindNavigationKeyDown(
    _ event: NSEvent,
    controller: TextViewController
  ) -> NSEvent? {
    let returnKey: UInt16 = 36
    let keypadEnterKey: UInt16 = 76
    guard event.keyCode == returnKey || event.keyCode == keypadEnterKey else {
      return event
    }

    let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifierFlags.subtracting(.shift).isEmpty else {
      return event
    }

    if controller.view.window?.firstResponder === controller.textView,
       isUsingFindPanelNavigation == false {
      return event
    }

    let direction: SourceEditorFindNavigationDirection = modifierFlags.contains(.shift)
      ? .previous
      : .next
    navigateFindMatch(direction, in: controller)
    return nil
  }

  private func handleFindNavigationMouseDown(
    _ event: NSEvent,
    controller: TextViewController
  ) -> NSEvent? {
    guard let findPanel = SourceEditorFindPanelHitTestingFix.findPanel(in: controller.view),
          findPanel.isHidden == false else {
      return event
    }

    let panelPoint = findPanel.convert(event.locationInWindow, from: nil)
    isUsingFindPanelNavigation = findPanel.bounds.contains(panelPoint)
    return event
  }

  private func handleFindNavigationMouseUp(
    _ event: NSEvent,
    controller: TextViewController
  ) -> NSEvent? {
    guard let findPanel = SourceEditorFindPanelHitTestingFix.findPanel(in: controller.view),
          findPanel.isHidden == false else {
      return event
    }

    let panelPoint = findPanel.convert(event.locationInWindow, from: nil)
    guard let direction = SourceEditorFindNavigationControlRegion.direction(
      for: panelPoint,
      panelSize: findPanel.bounds.size
    ) else {
      return event
    }

    navigateFindMatch(direction, in: controller)
    return nil
  }

  private func navigateFindMatch(
    _ direction: SourceEditorFindNavigationDirection,
    in controller: TextViewController
  ) {
    syncFindNavigationTextFromPanel(in: controller)
    let codeEditFindEmphases = controller.textView.emphasisManager?
      .getEmphases(for: SourceEditorFindNavigator.codeEditFindEmphasisGroup)
      .sorted { $0.range.location < $1.range.location } ?? []
    let codeEditFindRanges = codeEditFindEmphases.map(\.range)
    let activeFindRange = codeEditFindEmphases.first { $0.selectInDocument }?.range
      ?? codeEditFindEmphases.first { !$0.inactive }?.range
    let currentRange = lastFindNavigationRange
      ?? activeFindRange
      ?? controller.cursorPositions.first?.range
    guard let range = SourceEditorFindNavigator.targetRange(
      matches: codeEditFindRanges.isEmpty
        ? SourceEditorFindNavigator.matchRanges(query: findNavigationText, in: controller.text)
        : codeEditFindRanges,
      currentRange: currentRange,
      direction: direction
    ) else {
      NSSound.beep()
      return
    }

    isUsingFindPanelNavigation = true
    lastFindNavigationRange = range
    controller.setCursorPositions([CursorPosition(range: range)], scrollToVisible: true)
    scrollFindMatch(range, in: controller)
  }

  private func shouldHandleFindNavigation(in controller: TextViewController) -> Bool {
    isFindPanelVisible || SourceEditorFindPanelHitTestingFix.isFindPanelVisible(in: controller.view)
  }

  private func syncFindNavigationTextFromPanel(in controller: TextViewController) {
    guard let panelText = SourceEditorFindPanelHitTestingFix.findText(in: controller.view) else {
      return
    }
    if panelText != findNavigationText {
      lastFindNavigationRange = nil
    }
    findNavigationText = panelText
  }

  private func isFindMatchRange(_ range: NSRange, in controller: TextViewController) -> Bool {
    guard range.location != NSNotFound, !findNavigationText.isEmpty else { return false }
    let codeEditFindRanges = controller.textView.emphasisManager?
      .getEmphases(for: SourceEditorFindNavigator.codeEditFindEmphasisGroup)
      .map(\.range) ?? []
    let findRanges = codeEditFindRanges.isEmpty
      ? SourceEditorFindNavigator.matchRanges(query: findNavigationText, in: controller.text)
      : codeEditFindRanges
    return findRanges.contains(range)
  }

  private func scrollFindMatch(_ range: NSRange, in controller: TextViewController) {
    guard range.location != NSNotFound else { return }
    controller.textView.scrollToRange(range, center: true)

    DispatchQueue.main.async { [weak controller] in
      guard let controller else { return }
      controller.textView.scrollToRange(range, center: true)
      controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    }
  }
}

// MARK: - SourceEditorLanguageResolver

enum SourceEditorLanguageResolver {
  static func languageIdentifier(
    forFileName fileName: String,
    content: String,
    displayMode: EditorDisplayMode
  ) -> String {
    language(forFileName: fileName, content: content, displayMode: displayMode).tsName
  }

  static func language(
    forFileName fileName: String,
    content: String,
    displayMode: EditorDisplayMode
  ) -> CodeLanguage {
    guard displayMode.highlightsSyntax, !fileName.isEmpty else {
      return .default
    }

    return CodeLanguage.detectLanguageFrom(
      url: URL(fileURLWithPath: fileName),
      prefixBuffer: prefixBuffer(from: content),
      suffixBuffer: suffixBuffer(from: content)
    )
  }

  private static func prefixBuffer(from content: String, maxLines: Int = 8) -> String {
    guard !content.isEmpty else { return "" }
    var endIndex = content.startIndex
    var newlineCount = 0

    while endIndex < content.endIndex, newlineCount < maxLines {
      if content[endIndex].isNewline {
        newlineCount += 1
      }
      endIndex = content.index(after: endIndex)
    }

    return String(content[..<endIndex])
  }

  private static func suffixBuffer(from content: String, maxLines: Int = 8) -> String {
    guard !content.isEmpty else { return "" }
    var startIndex = content.endIndex
    var newlineCount = 0

    while startIndex > content.startIndex, newlineCount < maxLines {
      let previousIndex = content.index(before: startIndex)
      if content[previousIndex].isNewline {
        newlineCount += 1
        if newlineCount == maxLines {
          startIndex = content.index(after: previousIndex)
          break
        }
      }
      startIndex = previousIndex
    }

    return String(content[startIndex...])
  }
}

// MARK: - AgentHubSourceEditorTheme

private enum AgentHubSourceEditorTheme {
  static func theme(for colorScheme: ColorScheme) -> EditorTheme {
    switch colorScheme {
    case .dark:
      darkTheme(resolvingIn: .darkAqua)
    case .light:
      lightTheme(resolvingIn: .aqua)
    @unknown default:
      lightTheme(resolvingIn: .aqua)
    }
  }

  private static func lightTheme(resolvingIn appearanceName: NSAppearance.Name) -> EditorTheme {
    EditorTheme(
      text: .init(color: rgb(.labelColor, resolvingIn: appearanceName)),
      insertionPoint: rgb(.controlAccentColor, resolvingIn: appearanceName),
      invisibles: .init(color: rgb(.tertiaryLabelColor, resolvingIn: appearanceName)),
      background: rgb(.textBackgroundColor, resolvingIn: appearanceName),
      lineHighlight: rgb(NSColor.black.withAlphaComponent(0.05), resolvingIn: appearanceName),
      selection: rgb(.selectedTextBackgroundColor, resolvingIn: appearanceName),
      keywords: .init(color: rgb(.systemPurple, resolvingIn: appearanceName)),
      commands: .init(color: rgb(.systemBlue, resolvingIn: appearanceName)),
      types: .init(color: rgb(.systemTeal, resolvingIn: appearanceName)),
      attributes: .init(color: rgb(.systemIndigo, resolvingIn: appearanceName)),
      variables: .init(color: rgb(.labelColor, resolvingIn: appearanceName)),
      values: .init(color: rgb(.systemMint, resolvingIn: appearanceName)),
      numbers: .init(color: rgb(.systemOrange, resolvingIn: appearanceName)),
      strings: .init(color: rgb(.systemRed, resolvingIn: appearanceName)),
      characters: .init(color: rgb(.systemPink, resolvingIn: appearanceName)),
      comments: .init(color: rgb(.secondaryLabelColor, resolvingIn: appearanceName), italic: true)
    )
  }

  private static func darkTheme(resolvingIn appearanceName: NSAppearance.Name) -> EditorTheme {
    EditorTheme(
      text: .init(color: rgb(.labelColor, resolvingIn: appearanceName)),
      insertionPoint: rgb(.controlAccentColor, resolvingIn: appearanceName),
      invisibles: .init(color: rgb(.tertiaryLabelColor, resolvingIn: appearanceName)),
      background: rgb(.windowBackgroundColor, resolvingIn: appearanceName),
      lineHighlight: rgb(NSColor.white.withAlphaComponent(0.08), resolvingIn: appearanceName),
      selection: rgb(.selectedTextBackgroundColor, resolvingIn: appearanceName),
      keywords: .init(color: rgb(.systemPurple, resolvingIn: appearanceName)),
      commands: .init(color: rgb(.systemBlue, resolvingIn: appearanceName)),
      types: .init(color: rgb(.systemTeal, resolvingIn: appearanceName)),
      attributes: .init(color: rgb(.systemIndigo, resolvingIn: appearanceName)),
      variables: .init(color: rgb(.labelColor, resolvingIn: appearanceName)),
      values: .init(color: rgb(.systemMint, resolvingIn: appearanceName)),
      numbers: .init(color: rgb(.systemOrange, resolvingIn: appearanceName)),
      strings: .init(color: rgb(.systemRed, resolvingIn: appearanceName)),
      characters: .init(color: rgb(.systemPink, resolvingIn: appearanceName)),
      comments: .init(color: rgb(.secondaryLabelColor, resolvingIn: appearanceName), italic: true)
    )
  }

  // CodeEditSourceEditor reads color components (e.g. brightness) from theme
  // colors; catalog/system NSColors throw until resolved into an RGB colorspace.
  private static func rgb(_ color: NSColor, resolvingIn appearanceName: NSAppearance.Name) -> NSColor {
    guard let appearance = NSAppearance(named: appearanceName) else {
      return color.usingColorSpace(.sRGB) ?? color
    }

    var resolvedColor = color
    appearance.performAsCurrentDrawingAppearance {
      resolvedColor = color.usingColorSpace(.sRGB) ?? color
    }
    return resolvedColor
  }
}
