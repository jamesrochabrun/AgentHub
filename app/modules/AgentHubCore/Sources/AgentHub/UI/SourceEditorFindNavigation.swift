//
//  SourceEditorFindNavigation.swift
//  AgentHub
//
//  Local repairs for CodeEditSourceEditor's embedded find panel.
//

import AppKit
import CodeEditSourceEditor

// MARK: - SourceEditorFindPanelHitTestingFix

enum SourceEditorFindPanelHitTestingFix {
  @discardableResult
  static func apply(to controller: TextViewController) -> Bool {
    bringFindPanelToFront(in: controller.view)
  }

  @discardableResult
  static func bringFindPanelToFront(in rootView: NSView) -> Bool {
    if let findPanel = directFindPanel(in: rootView) {
      guard rootView.subviews.last !== findPanel else { return false }
      rootView.addSubview(findPanel, positioned: .above, relativeTo: nil)
      findPanel.wantsLayer = true
      findPanel.layer?.zPosition = 1000
      return true
    }

    for subview in rootView.subviews {
      if bringFindPanelToFront(in: subview) {
        return true
      }
    }

    return false
  }

  static func findPanel(in rootView: NSView) -> NSView? {
    if let findPanel = directFindPanel(in: rootView) {
      return findPanel
    }

    for subview in rootView.subviews {
      if let findPanel = findPanel(in: subview) {
        return findPanel
      }
    }

    return nil
  }

  static func isFindPanelVisible(in rootView: NSView) -> Bool {
    guard let findPanel = findPanel(in: rootView) else { return false }
    return findPanel.isHidden == false && findPanel.window != nil && findPanel.bounds.height > 0
  }

  static func findText(in rootView: NSView) -> String? {
    guard let findPanel = findPanel(in: rootView) else { return nil }
    return textFieldValues(in: findPanel)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  private static func directFindPanel(in rootView: NSView) -> NSView? {
    rootView.subviews.first(where: isFindPanelHostingView)
  }

  private static func isFindPanelHostingView(_ view: NSView) -> Bool {
    String(describing: type(of: view)) == "FindPanelHostingView"
  }

  private static func textFieldValues(in rootView: NSView) -> [String] {
    var values: [String] = []
    if let textField = rootView as? NSTextField {
      values.append(textField.stringValue)
    }

    for subview in rootView.subviews {
      values.append(contentsOf: textFieldValues(in: subview))
    }

    return values
  }
}

// MARK: - SourceEditorFindNavigator

enum SourceEditorFindNavigationDirection {
  case next
  case previous
}

enum SourceEditorFindNavigator {
  static let codeEditFindEmphasisGroup = "codeedit.find"

  static func matchRanges(query: String, in text: String) -> [NSRange] {
    guard !query.isEmpty else { return [] }
    let pattern = NSRegularExpression.escapedPattern(for: query)
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return []
    }
    let searchRange = NSRange(location: 0, length: (text as NSString).length)
    return regex.matches(in: text, range: searchRange)
      .map(\.range)
      .filter { !$0.isEmpty }
  }

  static func targetRange(
    query: String,
    text: String,
    currentRange: NSRange?,
    direction: SourceEditorFindNavigationDirection
  ) -> NSRange? {
    targetRange(
      matches: matchRanges(query: query, in: text),
      currentRange: currentRange,
      direction: direction
    )
  }

  static func targetRange(
    matches: [NSRange],
    currentRange: NSRange?,
    direction: SourceEditorFindNavigationDirection
  ) -> NSRange? {
    guard !matches.isEmpty else { return nil }

    guard let currentRange else {
      return direction == .next ? matches.first : matches.last
    }

    switch direction {
    case .next:
      return matches.first { $0.location > currentRange.location } ?? matches.first
    case .previous:
      return matches.last { $0.location < currentRange.location } ?? matches.last
    }
  }
}

enum SourceEditorFindNavigationControlRegion {
  static func direction(
    for point: CGPoint,
    panelSize: CGSize
  ) -> SourceEditorFindNavigationDirection? {
    guard panelSize.width > 0,
          point.x >= 0,
          point.x <= panelSize.width,
          point.y >= 0,
          point.y <= panelSize.height else {
      return nil
    }

    let doneButtonWidth: CGFloat = panelSize.width < 360 ? 32 : 54
    let navigationGroupWidth: CGFloat = panelSize.width < 360 ? 54 : 66
    let trailingInset: CGFloat = 4
    let navigationMaxX = panelSize.width - doneButtonWidth - trailingInset
    let navigationMinX = navigationMaxX - navigationGroupWidth

    guard point.x >= navigationMinX, point.x <= navigationMaxX else {
      return nil
    }

    return point.x < navigationMinX + navigationGroupWidth / 2 ? .previous : .next
  }
}
