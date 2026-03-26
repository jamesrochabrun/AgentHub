//
//  SourceCodeEditorView.swift
//  AgentHub
//
//  Shared source editor used by the file explorer and web preview inspector rail.
//

import AppKit
import CodeEditTextView
import HighlightSwift
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

  @State private var showFindBar = false
  @State private var findQuery = ""
  @State private var findMatchRanges: [NSRange] = []
  @State private var findCurrentIndex = 0
  @State private var findCaseSensitive = false
  @State private var coordinatorRef = CoordinatorRef()
  @State private var findDebounceTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      if showFindBar {
        FindBarView(
          query: $findQuery,
          currentIndex: findCurrentIndex,
          totalMatches: findMatchRanges.count,
          caseSensitive: $findCaseSensitive,
          onNext: { navigateFind(delta: 1) },
          onPrevious: { navigateFind(delta: -1) },
          onDismiss: { dismissFindBar() },
          onQueryChanged: { debouncedFind() },
          onCaseSensitiveChanged: { performFind() }
        )
        Divider()
      }

      CETextViewRepresentable(
        text: $text,
        fileName: fileName,
        documentID: documentID,
        displayMode: displayMode,
        isEditable: isEditable,
        coordinatorRef: coordinatorRef,
        onTextChange: onTextChange,
        onIdleTextSnapshot: onIdleTextSnapshot,
        onTextEditedWhileSearching: showFindBar ? { performFind() } : nil
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background {
      Button("") {
        toggleFindBar()
      }
      .keyboardShortcut("f", modifiers: .command)
      .opacity(0)
      .frame(width: 0, height: 0)
    }
  }

  private func toggleFindBar() {
    if showFindBar {
      dismissFindBar()
    } else {
      showFindBar = true
    }
  }

  private func dismissFindBar() {
    showFindBar = false
    findQuery = ""
    findMatchRanges = []
    findCurrentIndex = 0
    coordinatorRef.coordinator?.clearSearchHighlights()
  }

  private func debouncedFind() {
    findDebounceTask?.cancel()
    findDebounceTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      performFind()
    }
  }

  private func performFind() {
    guard let coordinator = coordinatorRef.coordinator else { return }
    let ranges = coordinator.performSearch(query: findQuery, caseSensitive: findCaseSensitive)
    findMatchRanges = ranges
    if ranges.isEmpty {
      findCurrentIndex = 0
    } else {
      findCurrentIndex = 1
      coordinator.navigateToMatch(at: 0, allRanges: ranges)
    }
  }

  private func navigateFind(delta: Int) {
    guard !findMatchRanges.isEmpty,
          let coordinator = coordinatorRef.coordinator else {
      return
    }

    let count = findMatchRanges.count
    let zeroBasedIndex = findCurrentIndex - 1
    let newIndex = ((zeroBasedIndex + delta) % count + count) % count
    findCurrentIndex = newIndex + 1
    coordinator.navigateToMatch(at: newIndex, allRanges: findMatchRanges)
  }
}

// MARK: - CoordinatorRef

final class CoordinatorRef {
  weak var coordinator: CETextViewRepresentable.Coordinator?
}

// MARK: - FindBarView

private struct FindBarView: View {
  @Binding var query: String
  let currentIndex: Int
  let totalMatches: Int
  @Binding var caseSensitive: Bool
  let onNext: () -> Void
  let onPrevious: () -> Void
  let onDismiss: () -> Void
  let onQueryChanged: () -> Void
  let onCaseSensitiveChanged: () -> Void

  @FocusState private var isFieldFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
        TextField("Find…", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 12, design: .monospaced))
          .focused($isFieldFocused)
          .onSubmit { onNext() }
          .onChange(of: query) { _, _ in
            onQueryChanged()
          }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.primary.opacity(0.06))
      )
      .frame(minWidth: 140, maxWidth: 260)

      if !query.isEmpty {
        Text(totalMatches == 0 ? "No results" : "\(currentIndex) of \(totalMatches)")
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(totalMatches == 0 ? .red.opacity(0.8) : .secondary)
          .frame(minWidth: 60)
      }

      Button(action: onPrevious) {
        Image(systemName: "chevron.up")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .disabled(totalMatches == 0)

      Button(action: onNext) {
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .disabled(totalMatches == 0)

      Button {
        caseSensitive.toggle()
        onCaseSensitiveChanged()
      } label: {
        Text("Aa")
          .font(.system(size: 11, weight: caseSensitive ? .bold : .regular))
          .foregroundColor(caseSensitive ? .accentColor : .secondary)
          .frame(width: 22, height: 22)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(caseSensitive ? Color.accentColor.opacity(0.15) : Color.clear)
          )
      }
      .buttonStyle(.plain)

      Spacer()

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.surfaceElevated)
    .onAppear { isFieldFocused = true }
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
    .onKeyPress(.return, phases: .down) { event in
      if event.modifiers.contains(.shift) {
        onPrevious()
        return .handled
      }
      return .ignored
    }
  }
}

// MARK: - CETextViewRepresentable

struct CETextViewRepresentable: NSViewRepresentable {
  @Binding var text: String
  let fileName: String
  let documentID: UUID
  let displayMode: EditorDisplayMode
  let isEditable: Bool
  var coordinatorRef: CoordinatorRef?
  let onTextChange: (String) -> Void
  let onIdleTextSnapshot: (String) -> Void
  var onTextEditedWhileSearching: (() -> Void)?
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.contentView.postsFrameChangedNotifications = true
    scrollView.contentView.postsBoundsChangedNotifications = true

    let textView = TextView(
      string: text,
      font: .monospacedSystemFont(ofSize: 12, weight: .regular),
      textColor: .labelColor,
      lineHeightMultiplier: 1.3,
      wrapLines: false,
      isEditable: isEditable,
      isSelectable: true,
      letterSpacing: 1.0,
      useSystemCursor: true,
      delegate: context.coordinator
    )
    textView.edgeInsets = HorizontalEdgeInsets(left: 8, right: 8)

    scrollView.documentView = textView
    textView.updateFrameIfNeeded()

    // Line number gutter
    let gutterView = LineNumberGutterView(textView: textView, scrollView: scrollView)
    scrollView.hasVerticalRuler = true
    scrollView.verticalRulerView = gutterView
    scrollView.rulersVisible = true

    context.coordinator.textView = textView
    context.coordinator.gutterView = gutterView
    coordinatorRef?.coordinator = context.coordinator
    context.coordinator.loadDocument(
      text: text,
      fileName: fileName,
      documentID: documentID,
      displayMode: displayMode,
      colorScheme: colorScheme
    )
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard context.coordinator.textView != nil else { return }

    if context.coordinator.currentDocumentID != documentID {
      context.coordinator.loadDocument(
        text: text,
        fileName: fileName,
        documentID: documentID,
        displayMode: displayMode,
        colorScheme: colorScheme
      )
      return
    }

    if let textView = context.coordinator.textView, textView.isEditable != isEditable {
      textView.isEditable = isEditable
    }

    if context.coordinator.currentDisplayMode != displayMode {
      context.coordinator.currentDisplayMode = displayMode
      if displayMode.highlightsSyntax {
        context.coordinator.applySyntaxHighlighting(
          text: text,
          fileName: fileName,
          colorScheme: colorScheme
        )
      } else {
        context.coordinator.applyPlainTextAppearance()
      }
    }

    if context.coordinator.lastColorScheme != colorScheme {
      context.coordinator.lastColorScheme = colorScheme
      if displayMode.highlightsSyntax {
        context.coordinator.applySyntaxHighlighting(
          text: text,
          fileName: fileName,
          colorScheme: colorScheme
        )
      } else {
        context.coordinator.applyPlainTextAppearance()
      }
    }
  }

  final class Coordinator: NSObject, TextViewDelegate {
    var parent: CETextViewRepresentable
    weak var textView: TextView?
    var isUpdatingFromBinding = false
    var currentDocumentID: UUID?
    var currentDisplayMode: EditorDisplayMode = .highlighted
    var lastColorScheme: ColorScheme?
    weak var gutterView: LineNumberGutterView?
    private var highlightTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private let highlighter = Highlight()

    init(parent: CETextViewRepresentable) {
      self.parent = parent
    }

    func loadDocument(
      text: String,
      fileName: String,
      documentID: UUID,
      displayMode: EditorDisplayMode,
      colorScheme: ColorScheme
    ) {
      guard let textView else { return }
      highlightTask?.cancel()
      idleTask?.cancel()
      currentDocumentID = documentID
      currentDisplayMode = displayMode
      lastColorScheme = colorScheme

      isUpdatingFromBinding = true
      textView.string = text
      textView.textColor = .labelColor
      textView.wrapLines = false
      textView.updateFrameIfNeeded()
      isUpdatingFromBinding = false

      if displayMode.highlightsSyntax {
        applySyntaxHighlighting(text: text, fileName: fileName, colorScheme: colorScheme)
      } else {
        applyPlainTextAppearance()
      }

      gutterView?.updateGutterWidth()
    }

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
      guard !isUpdatingFromBinding else { return }
      let newText = textView.string
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.parent.text = newText
        self.parent.onTextChange(newText)
      }
      gutterView?.updateGutterWidth()
      schedulePostEditWork(text: newText)
      if let callback = parent.onTextEditedWhileSearching {
        scheduleSearchRefresh(callback: callback)
      }
    }

    func applySyntaxHighlighting(text: String, fileName: String, colorScheme: ColorScheme) {
      highlightTask?.cancel()
      guard currentDisplayMode.highlightsSyntax else {
        applyPlainTextAppearance()
        return
      }
      guard !text.isEmpty else { return }

      let lang = Self.languageForFile(fileName)
      let colors: HighlightColors = colorScheme == .dark ? .dark(.github) : .light(.github)

      highlightTask = Task { [weak self, highlighter] in
        guard let self else { return }
        do {
          let attributed: AttributedString
          if let lang {
            attributed = try await highlighter.attributedText(text, language: lang, colors: colors)
          } else {
            attributed = try await highlighter.attributedText(text, colors: colors)
          }
          guard !Task.isCancelled else { return }

          let leadingWS = text.prefix(while: { $0.isWhitespace || $0.isNewline })
          let leadingOffset = (leadingWS as Substring).utf16.count

          let nsHighlighted = NSAttributedString(attributed)
          var colorRanges: [(NSRange, NSColor)] = []
          nsHighlighted.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: nsHighlighted.length),
            options: []
          ) { value, range, _ in
            if let color = value as? NSColor {
              colorRanges.append((range, color))
            }
          }

          let resolvedColorRanges = colorRanges
          guard !Task.isCancelled, !resolvedColorRanges.isEmpty else { return }
          await MainActor.run { [weak self] in
            self?.applyHighlightColors(resolvedColorRanges, leadingOffset: leadingOffset)
          }
        } catch {
          // Render the document without syntax colors on failure.
        }
      }
    }

    func performSearch(query: String, caseSensitive: Bool) -> [NSRange] {
      guard let textView, !query.isEmpty else {
        clearSearchHighlights()
        return []
      }

      let nsString = textView.string as NSString
      let textLength = nsString.length
      guard textLength > 0 else { return [] }

      let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
      var searchRange = NSRange(location: 0, length: textLength)
      var ranges: [NSRange] = []

      while searchRange.location < textLength {
        let foundRange = nsString.range(of: query, options: options, range: searchRange)
        guard foundRange.location != NSNotFound else { break }
        ranges.append(foundRange)
        searchRange.location = foundRange.location + foundRange.length
        searchRange.length = textLength - searchRange.location
      }

      guard !ranges.isEmpty else {
        clearSearchHighlights()
        return []
      }

      let renderCount = min(ranges.count, Self.maxRenderedEmphases)
      let emphases = (0..<renderCount).map { idx in
        Emphasis(range: ranges[idx], style: .standard, inactive: idx != 0)
      }
      textView.emphasisManager?.replaceEmphases(emphases, for: Self.findGroupID)
      textView.scrollToRange(ranges[0], center: true)

      return ranges
    }

    func navigateToMatch(at index: Int, allRanges: [NSRange]) {
      guard let textView, !allRanges.isEmpty else { return }
      let renderCount = min(allRanges.count, Self.maxRenderedEmphases)
      let previousIndex = lastActiveIndex
      lastActiveIndex = index

      if previousIndex < renderCount, index < renderCount {
        textView.emphasisManager?.updateEmphases(for: Self.findGroupID) { existing in
          var updated = existing
          if previousIndex < updated.count {
            let old = updated[previousIndex]
            updated[previousIndex] = Emphasis(range: old.range, style: .standard, inactive: true)
          }
          if index < updated.count {
            let current = updated[index]
            updated[index] = Emphasis(range: current.range, style: .standard, inactive: false)
          }
          return updated
        }
      } else {
        let emphases = (0..<renderCount).map { idx in
          Emphasis(range: allRanges[idx], style: .standard, inactive: idx != index)
        }
        textView.emphasisManager?.replaceEmphases(emphases, for: Self.findGroupID)
      }

      textView.scrollToRange(allRanges[index], center: true)
    }

    func clearSearchHighlights() {
      textView?.emphasisManager?.removeEmphases(for: Self.findGroupID)
    }

    func scheduleSearchRefresh(callback: @escaping () -> Void) {
      searchDebounceTask?.cancel()
      searchDebounceTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        callback()
      }
    }

    private func schedulePostEditWork(text: String) {
      idleTask?.cancel()
      let fileName = parent.fileName
      let colorScheme = lastColorScheme ?? .light
      let displayMode = currentDisplayMode
      idleTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled else { return }
        await MainActor.run { [weak self] in
          self?.parent.onIdleTextSnapshot(text)
        }
        guard !Task.isCancelled, displayMode.highlightsSyntax else { return }
        self?.applySyntaxHighlighting(text: text, fileName: fileName, colorScheme: colorScheme)
      }
    }

    private func applyHighlightColors(_ colorRanges: [(NSRange, NSColor)], leadingOffset: Int) {
      guard let textView, let storage = textView.textStorage else { return }
      let storageLen = storage.length
      guard storageLen > 0 else { return }

      storage.beginEditing()
      let fullRange = NSRange(location: 0, length: storageLen)
      storage.removeAttribute(.foregroundColor, range: fullRange)
      storage.addAttribute(.foregroundColor, value: textView.textColor, range: fullRange)

      for (range, color) in colorRanges {
        let adjusted = NSRange(location: range.location + leadingOffset, length: range.length)
        if adjusted.location >= 0, adjusted.location + adjusted.length <= storageLen {
          storage.addAttribute(.foregroundColor, value: color, range: adjusted)
        }
      }

      storage.endEditing()
      textView.layoutManager?.setNeedsLayout()
      textView.needsLayout = true
      textView.needsDisplay = true
    }

    func applyPlainTextAppearance() {
      highlightTask?.cancel()
      guard let textView, let storage = textView.textStorage else { return }
      let storageLen = storage.length
      guard storageLen > 0 else { return }

      let fullRange = NSRange(location: 0, length: storageLen)
      storage.beginEditing()
      storage.removeAttribute(.foregroundColor, range: fullRange)
      storage.addAttribute(.foregroundColor, value: textView.textColor, range: fullRange)
      storage.endEditing()
      textView.layoutManager?.setNeedsLayout()
      textView.needsLayout = true
      textView.needsDisplay = true
    }

    private static let findGroupID = "find"
    private static let maxRenderedEmphases = 500
    private var searchDebounceTask: Task<Void, Never>?
    private var lastActiveIndex: Int = 0

    static func languageForFile(_ name: String) -> HighlightLanguage? {
      let ext = (name as NSString).pathExtension.lowercased()
      switch ext {
      case "swift": return .swift
      case "js", "jsx": return .javaScript
      case "ts", "tsx": return .typeScript
      case "py": return .python
      case "rb": return .ruby
      case "go": return .go
      case "rs": return .rust
      case "java": return .java
      case "kt": return .kotlin
      case "c", "h": return .c
      case "cpp", "cxx", "cc", "hpp": return .cPlusPlus
      case "cs": return .cSharp
      case "php": return .php
      case "html", "htm": return .html
      case "css": return .css
      case "scss": return .scss
      case "json": return .json
      case "yaml", "yml": return .yaml
      case "toml": return .toml
      case "xml": return .html
      case "sql": return .sql
      case "sh", "bash", "zsh": return .bash
      case "md", "markdown": return .markdown
      case "dockerfile": return .dockerfile
      case "makefile": return .makefile
      case "lua": return .lua
      case "r": return .r
      case "dart": return .dart
      case "scala": return .scala
      case "diff", "patch": return .diff
      default: return nil
      }
    }
  }
}
