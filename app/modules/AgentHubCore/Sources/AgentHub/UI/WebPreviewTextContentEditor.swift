//
//  WebPreviewTextContentEditor.swift
//  AgentHub
//
//  Text-content editor for the Edit Mode toolbar.
//
//  Owns a local draft instead of binding straight to the element snapshot: the
//  page reports element text trimmed and whitespace-collapsed after every DOM
//  mutation, so a direct binding erased trailing spaces mid-keystroke. It also
//  scrolls instead of clipping, so long strings stay editable past the last
//  visible line.
//

import SwiftUI

struct WebPreviewTextContentEditor: View {
  /// Stable identity of the element being edited; a change reseeds the draft.
  let elementKey: String
  /// Text as last read from the page or source.
  let sourceText: String
  let onTextChange: (String) -> Void

  @State private var draft = ""
  @State private var lastEmitted = ""
  @State private var seededKey: String?
  @State private var measuredTextHeight: CGFloat = 0
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "text.quote")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.top, 3)

      editor
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
    )
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .onAppear { seed(with: sourceText, key: elementKey) }
    .onChange(of: elementKey) { _, newKey in
      seed(with: sourceText, key: newKey)
    }
    .onChange(of: sourceText) { _, newText in
      guard WebPreviewTextDraftPolicy.shouldAdoptIncomingText(
        newText,
        draft: draft,
        isEditing: isFocused
      ) else { return }
      seed(with: newText, key: elementKey)
    }
    .onChange(of: draft) { _, newValue in
      guard seededKey == elementKey, newValue != lastEmitted else { return }
      lastEmitted = newValue
      onTextChange(newValue)
    }
  }

  private var editor: some View {
    TextEditor(text: $draft)
      .focused($isFocused)
      .font(.system(size: Self.fontSize))
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .frame(height: editorHeight)
      .frame(minWidth: 220, idealWidth: 360, maxWidth: 520)
      .background(alignment: .topLeading) { heightProbe }
  }

  /// Off-screen copy of the draft, laid out at the editor's width, used to grow
  /// the editor with its content up to `maxHeight` (it scrolls past that).
  private var heightProbe: some View {
    Text(draft.isEmpty ? " " : draft)
      .font(.system(size: Self.fontSize))
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, Self.textEditorTextInset)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: TextHeightPreferenceKey.self, value: proxy.size.height)
        }
      )
      .hidden()
      .onPreferenceChange(TextHeightPreferenceKey.self) { height in
        measuredTextHeight = height
      }
  }

  private var editorHeight: CGFloat {
    min(max(measuredTextHeight + Self.textEditorVerticalInset, Self.minHeight), Self.maxHeight)
  }

  private func seed(with text: String, key: String) {
    draft = text
    lastEmitted = text
    seededKey = key
  }

  private static let fontSize: CGFloat = 13
  private static let minHeight: CGFloat = 20
  private static let maxHeight: CGFloat = 96
  /// TextEditor insets its text; the probe matches it so wrapping lines up.
  private static let textEditorTextInset: CGFloat = 5
  private static let textEditorVerticalInset: CGFloat = 4
}

private struct TextHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
