import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentHubCore

private final class FindPanelHostingView: NSView {}

private func withCurrentDrawingAppearance<T>(_ name: NSAppearance.Name, _ body: () -> T) -> T {
  guard let appearance = NSAppearance(named: name) else { return body() }

  var result: T?
  appearance.performAsCurrentDrawingAppearance {
    result = body()
  }
  return result ?? body()
}

private func brightness(of color: NSColor) -> CGFloat {
  (color.usingColorSpace(.sRGB) ?? color).brightnessComponent
}

@Suite("SourceCodeEditorView")
struct SourceCodeEditorViewTests {
  @Test("Find panel repair brings CodeEdit find panel to the hit-test front")
  func findPanelRepairBringsPanelToFront() {
    let rootView = NSView()
    let codeEditContainer = NSView()
    let findPanel = FindPanelHostingView()
    let editorScrollView = NSScrollView()

    rootView.addSubview(codeEditContainer)
    codeEditContainer.addSubview(findPanel)
    codeEditContainer.addSubview(editorScrollView)

    let didRepair = SourceEditorFindPanelHitTestingFix.bringFindPanelToFront(in: rootView)

    #expect(didRepair)
    #expect(codeEditContainer.subviews.last === findPanel)
    #expect(findPanel.layer?.zPosition == 1000)
  }

  @Test("Find panel repair is a no-op when the panel is already in front")
  func findPanelRepairNoopsWhenPanelAlreadyInFront() {
    let codeEditContainer = NSView()
    let editorScrollView = NSScrollView()
    let findPanel = FindPanelHostingView()

    codeEditContainer.addSubview(editorScrollView)
    codeEditContainer.addSubview(findPanel)

    let didRepair = SourceEditorFindPanelHitTestingFix.bringFindPanelToFront(in: codeEditContainer)

    #expect(didRepair == false)
    #expect(codeEditContainer.subviews.last === findPanel)
  }

  @Test("Find panel visibility uses the actual embedded panel state")
  func findPanelVisibilityUsesEmbeddedPanelState() {
    let codeEditContainer = NSView()
    let findPanel = FindPanelHostingView(frame: CGRect(x: 0, y: 0, width: 240, height: 28))

    codeEditContainer.addSubview(findPanel)

    #expect(SourceEditorFindPanelHitTestingFix.isFindPanelVisible(in: codeEditContainer) == false)

    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 120), styleMask: [], backing: .buffered, defer: false)
    window.contentView = codeEditContainer

    #expect(SourceEditorFindPanelHitTestingFix.isFindPanelVisible(in: codeEditContainer))

    findPanel.isHidden = true
    #expect(SourceEditorFindPanelHitTestingFix.isFindPanelVisible(in: codeEditContainer) == false)
  }

  @Test("Find panel text is read from embedded text field")
  func findPanelTextIsReadFromEmbeddedTextField() {
    let codeEditContainer = NSView()
    let findPanel = FindPanelHostingView(frame: CGRect(x: 0, y: 0, width: 240, height: 28))
    let wrapper = NSView()
    let textField = NSTextField(string: " provider ")

    codeEditContainer.addSubview(findPanel)
    findPanel.addSubview(wrapper)
    wrapper.addSubview(textField)

    #expect(SourceEditorFindPanelHitTestingFix.findText(in: codeEditContainer) == "provider")
  }

  @Test("Find navigator advances and wraps through contains matches")
  func findNavigatorAdvancesAndWrapsThroughMatches() {
    let text = "provider\nlet providerValue = provider"
    let matches = SourceEditorFindNavigator.matchRanges(query: "provider", in: text)

    #expect(matches.map(\.location) == [0, 13, 29])
    #expect(
      SourceEditorFindNavigator.targetRange(
        matches: matches,
        currentRange: matches[0],
        direction: .next
      ) == matches[1]
    )
    #expect(
      SourceEditorFindNavigator.targetRange(
        matches: matches,
        currentRange: matches[2],
        direction: .next
      ) == matches[0]
    )
  }

  @Test("Find navigator moves backward and wraps")
  func findNavigatorMovesBackwardAndWraps() {
    let matches = [
      NSRange(location: 4, length: 3),
      NSRange(location: 12, length: 3),
      NSRange(location: 20, length: 3),
    ]

    #expect(
      SourceEditorFindNavigator.targetRange(
        matches: matches,
        currentRange: matches[1],
        direction: .previous
      ) == matches[0]
    )
    #expect(
      SourceEditorFindNavigator.targetRange(
        matches: matches,
        currentRange: matches[0],
        direction: .previous
      ) == matches[2]
    )
  }

  @Test("Find navigation control region maps only arrow button clicks")
  func findNavigationControlRegionMapsArrowButtons() {
    let panelSize = CGSize(width: 592, height: 28)

    #expect(
      SourceEditorFindNavigationControlRegion.direction(
        for: CGPoint(x: 480, y: 14),
        panelSize: panelSize
      ) == .previous
    )
    #expect(
      SourceEditorFindNavigationControlRegion.direction(
        for: CGPoint(x: 520, y: 14),
        panelSize: panelSize
      ) == .next
    )
    #expect(
      SourceEditorFindNavigationControlRegion.direction(
        for: CGPoint(x: 560, y: 14),
        panelSize: panelSize
      ) == nil
    )
  }

  @Test("Display mode enables highlighting for normal source files")
  func displayModeHighlightsNormalFiles() {
    let content = Array(repeating: "let value = 1", count: 1_000).joined(separator: "\n")

    #expect(EditorDisplayMode.displayMode(for: content) == .highlighted)
  }

  @Test("Display mode uses fast mode for large files")
  func displayModeUsesFastModeForLargeFiles() {
    let largeByteContent = String(repeating: "a", count: 300_001)
    let largeLineContent = Array(repeating: "line", count: 5_001).joined(separator: "\n")

    #expect(EditorDisplayMode.displayMode(for: largeByteContent) == .plainText)
    #expect(EditorDisplayMode.displayMode(for: largeLineContent) == .plainText)
  }

  @Test("Display mode uses fast mode for long-line files")
  func displayModeUsesFastModeForLongLineFiles() {
    let longLineContent = String(repeating: "a", count: 2_001)

    #expect(EditorDisplayMode.displayMode(for: longLineContent) == .plainText)
  }

  @Test("Text file metrics track bytes, lines, and longest line")
  func textFileMetricsTrackLargestLine() {
    let metrics = TextFileMetrics.metrics(for: "abc\nabcdef\nz")

    #expect(metrics.byteCount == 12)
    #expect(metrics.lineCount == 3)
    #expect(metrics.maxLineByteCount == 6)
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
    let plainText = AgentHubSourceEditorOptions(
      displayMode: .plainText,
      isEditable: true,
      isMinimapEnabled: false,
      isWrapLinesEnabled: true
    )

    #expect(wrapped.wrapLines)
    #expect(unwrapped.wrapLines == false)
    #expect(plainText.wrapLines == false)
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

  @Test("Editor theme resolves colors from requested color scheme")
  func editorThemeResolvesColorsFromRequestedColorScheme() {
    let options = AgentHubSourceEditorOptions(
      displayMode: .highlighted,
      isEditable: true,
      isMinimapEnabled: true,
      isWrapLinesEnabled: true
    )

    let lightThemeCreatedInDarkAppearance = withCurrentDrawingAppearance(.darkAqua) {
      options.makeSourceEditorConfiguration(colorScheme: .light).appearance.theme
    }
    let darkThemeCreatedInLightAppearance = withCurrentDrawingAppearance(.aqua) {
      options.makeSourceEditorConfiguration(colorScheme: .dark).appearance.theme
    }

    #expect(brightness(of: lightThemeCreatedInDarkAppearance.background) > 0.8)
    #expect(brightness(of: lightThemeCreatedInDarkAppearance.text.color) < 0.3)
    #expect(brightness(of: darkThemeCreatedInLightAppearance.background) < 0.3)
    #expect(brightness(of: darkThemeCreatedInLightAppearance.text.color) > 0.7)
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
