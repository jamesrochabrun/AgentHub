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
    let byteCount = content.utf8.count
    let lineCount = lineCount(for: content)
    if byteCount <= 300_000 && lineCount <= 5_000 {
      return .highlighted
    }
    return .plainText
  }

  private static func lineCount(for content: String) -> Int {
    guard !content.isEmpty else { return 0 }
    return content.utf8.reduce(into: 1) { count, byte in
      if byte == 0x0A {
        count += 1
      }
    }
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
  private var sourceEditorMinimapEnabled: Bool = false
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
      editCoordinator.syncExternalText(text)
    }
    .onChange(of: text) { _, newText in
      editCoordinator.syncExternalText(newText)
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
    isWrapLinesEnabled
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
  private var idleTask: Task<Void, Never>?
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
  }

  func textViewDidChangeText(controller: TextViewController) {
    guard !isApplyingExternalText else { return }
    let updatedText = controller.text
    onTextChange(updatedText)
    scheduleIdleSnapshot(updatedText)
  }

  func syncExternalText(_ text: String) {
    guard let controller, controller.text != text else { return }
    isApplyingExternalText = true
    controller.text = text
    isApplyingExternalText = false
  }

  func destroy() {
    idleTask?.cancel()
  }

  private func scheduleIdleSnapshot(_ text: String) {
    idleTask?.cancel()
    idleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled else { return }
      self?.onIdleTextSnapshot(text)
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
    colorScheme == .dark ? darkTheme() : lightTheme()
  }

  private static func lightTheme() -> EditorTheme {
    EditorTheme(
      text: .init(color: rgb(.labelColor)),
      insertionPoint: rgb(.controlAccentColor),
      invisibles: .init(color: rgb(.tertiaryLabelColor)),
      background: rgb(.textBackgroundColor),
      lineHighlight: rgb(NSColor.black.withAlphaComponent(0.05)),
      selection: rgb(.selectedTextBackgroundColor),
      keywords: .init(color: rgb(.systemPurple)),
      commands: .init(color: rgb(.systemBlue)),
      types: .init(color: rgb(.systemTeal)),
      attributes: .init(color: rgb(.systemIndigo)),
      variables: .init(color: rgb(.labelColor)),
      values: .init(color: rgb(.systemMint)),
      numbers: .init(color: rgb(.systemOrange)),
      strings: .init(color: rgb(.systemRed)),
      characters: .init(color: rgb(.systemPink)),
      comments: .init(color: rgb(.secondaryLabelColor), italic: true)
    )
  }

  private static func darkTheme() -> EditorTheme {
    EditorTheme(
      text: .init(color: rgb(.labelColor)),
      insertionPoint: rgb(.controlAccentColor),
      invisibles: .init(color: rgb(.tertiaryLabelColor)),
      background: rgb(.windowBackgroundColor),
      lineHighlight: rgb(NSColor.white.withAlphaComponent(0.08)),
      selection: rgb(.selectedTextBackgroundColor),
      keywords: .init(color: rgb(.systemPurple)),
      commands: .init(color: rgb(.systemBlue)),
      types: .init(color: rgb(.systemTeal)),
      attributes: .init(color: rgb(.systemIndigo)),
      variables: .init(color: rgb(.labelColor)),
      values: .init(color: rgb(.systemMint)),
      numbers: .init(color: rgb(.systemOrange)),
      strings: .init(color: rgb(.systemRed)),
      characters: .init(color: rgb(.systemPink)),
      comments: .init(color: rgb(.secondaryLabelColor), italic: true)
    )
  }

  // CodeEditSourceEditor reads color components (e.g. brightness) from theme
  // colors; catalog/system NSColors throw until resolved into an RGB colorspace.
  private static func rgb(_ color: NSColor) -> NSColor {
    color.usingColorSpace(.sRGB) ?? color
  }
}
