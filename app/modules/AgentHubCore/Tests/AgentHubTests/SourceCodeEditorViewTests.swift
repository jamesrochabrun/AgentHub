import Foundation
import Testing

@testable import AgentHubCore

@Suite("SourceCodeEditorView")
struct SourceCodeEditorViewTests {
  @Test("Display mode enables highlighting for normal source files")
  func displayModeHighlightsNormalFiles() {
    let content = String(repeating: "a", count: 300_000)

    #expect(EditorDisplayMode.displayMode(for: content) == .highlighted)
  }

  @Test("Display mode uses fast mode for large files")
  func displayModeUsesFastModeForLargeFiles() {
    let largeByteContent = String(repeating: "a", count: 300_001)
    let largeLineContent = Array(repeating: "line", count: 5_001).joined(separator: "\n")

    #expect(EditorDisplayMode.displayMode(for: largeByteContent) == .plainText)
    #expect(EditorDisplayMode.displayMode(for: largeLineContent) == .plainText)
  }

  @Test("Editor options use neutral spacing and disable line wrapping")
  func editorOptionsUseNeutralSpacingWithoutWrapping() {
    let options = AgentHubSourceEditorOptions(
      displayMode: .highlighted,
      isEditable: true,
      isMinimapEnabled: false,
      isWrapLinesEnabled: false
    )

    #expect(options.letterSpacing == 1.0)
    #expect(options.wrapLines == false)
  }

  @Test("Editor options enable wrapping only when the setting is on")
  func editorOptionsToggleWrapLinesBySetting() {
    let wrapped = AgentHubSourceEditorOptions(
      displayMode: .highlighted,
      isEditable: true,
      isMinimapEnabled: false,
      isWrapLinesEnabled: true
    )
    let unwrapped = AgentHubSourceEditorOptions(
      displayMode: .highlighted,
      isEditable: true,
      isMinimapEnabled: false,
      isWrapLinesEnabled: false
    )

    #expect(wrapped.wrapLines)
    #expect(unwrapped.wrapLines == false)
  }

  @Test("Editor options only enable minimap when the setting is on")
  func editorOptionsTogglePeripheralsByDisplayMode() {
    let highlightedWithMinimap = AgentHubSourceEditorOptions(
      displayMode: .highlighted,
      isEditable: true,
      isMinimapEnabled: true,
      isWrapLinesEnabled: false
    )
    let highlightedWithoutMinimap = AgentHubSourceEditorOptions(
      displayMode: .highlighted,
      isEditable: true,
      isMinimapEnabled: false,
      isWrapLinesEnabled: false
    )
    let plainTextWithMinimap = AgentHubSourceEditorOptions(
      displayMode: .plainText,
      isEditable: false,
      isMinimapEnabled: true,
      isWrapLinesEnabled: false
    )

    #expect(highlightedWithMinimap.showMinimap)
    #expect(highlightedWithoutMinimap.showMinimap == false)
    #expect(plainTextWithMinimap.showMinimap == false)
  }

  @Test("Editor options keep folding ribbon available for highlighted mode")
  func editorOptionsKeepFoldingRibbonForHighlightedMode() {
    let highlighted = AgentHubSourceEditorOptions(
      displayMode: .highlighted,
      isEditable: true,
      isMinimapEnabled: false,
      isWrapLinesEnabled: false
    )
    let plainText = AgentHubSourceEditorOptions(
      displayMode: .plainText,
      isEditable: false,
      isMinimapEnabled: false,
      isWrapLinesEnabled: false
    )

    #expect(highlighted.showFoldingRibbon)
    #expect(plainText.showFoldingRibbon == false)
  }

  @Test("Language resolver detects supported extensions and special filenames")
  func languageResolverDetectsSupportedFiles() {
    let cases: [(fileName: String, expectedIdentifier: String)] = [
      ("App.swift", "swift"),
      ("Component.tsx", "typescript"),
      ("package.json", "json"),
      ("README.md", "markdown"),
      ("Dockerfile", "dockerfile"),
      ("site.yaml", "yaml"),
    ]

    for testCase in cases {
      #expect(
        SourceEditorLanguageResolver.languageIdentifier(
          forFileName: testCase.fileName,
          content: "",
          displayMode: .highlighted
        ) == testCase.expectedIdentifier
      )
    }
  }

  @Test("Language resolver uses shebangs for extensionless scripts")
  func languageResolverUsesShebangs() {
    #expect(
      SourceEditorLanguageResolver.languageIdentifier(
        forFileName: "script",
        content: "#!/usr/bin/env python3\nprint('hello')",
        displayMode: .highlighted
      ) == "python"
    )
    #expect(
      SourceEditorLanguageResolver.languageIdentifier(
        forFileName: "runner",
        content: "#!/usr/bin/env node\nconsole.log('hello')",
        displayMode: .highlighted
      ) == "javascript"
    )
  }

  @Test("Language resolver falls back to plain text for fast mode and unsupported files")
  func languageResolverFallsBackToPlainText() {
    #expect(
      SourceEditorLanguageResolver.languageIdentifier(
        forFileName: "App.swift",
        content: "let value = 1",
        displayMode: .plainText
      ) == "PlainText"
    )
    #expect(
      SourceEditorLanguageResolver.languageIdentifier(
        forFileName: "Makefile",
        content: "build:\n\tswift build",
        displayMode: .highlighted
      ) == "PlainText"
    )
  }
}
