//
//  LineNumberGutterView.swift
//  AgentHub
//
//  Custom NSRulerView that displays line numbers aligned with
//  CodeEditTextView's text layout.
//

import AppKit
import CodeEditTextView

final class LineNumberGutterView: NSRulerView {

  private weak var textView: TextView?

  private let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  private let trailingPadding: CGFloat = 12
  private let leadingPadding: CGFloat = 8

  // MARK: - Init

  init(textView: TextView, scrollView: NSScrollView) {
    self.textView = textView
    super.init(
      scrollView: scrollView,
      orientation: .verticalRuler
    )
    ruleThickness = computeThickness(for: max(textView.layoutManager?.lineCount ?? 1, 1))
    self.clientView = textView
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: - Drawing

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView,
          let layoutManager = textView.layoutManager,
          let context = NSGraphicsContext.current?.cgContext else {
      return
    }

    // Background
    let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5)
    context.setFillColor(bgColor.cgColor)
    context.fill(rect)

    // Separator line on the right edge
    let separatorColor = NSColor.separatorColor
    context.setStrokeColor(separatorColor.cgColor)
    context.setLineWidth(0.5)
    let separatorX = bounds.maxX - 0.25
    context.move(to: CGPoint(x: separatorX, y: rect.minY))
    context.addLine(to: CGPoint(x: separatorX, y: rect.maxY))
    context.strokePath()

    let lineCount = layoutManager.lineCount
    guard lineCount > 0 else { return }

    // Visible area in the clip view's coordinate space
    guard let clipView = scrollView?.contentView else { return }
    let visibleRect = clipView.bounds

    // Text attributes for line numbers
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [
      .font: gutterFont,
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraphStyle,
    ]

    // Find the first visible line by Y position
    let visibleMinY = visibleRect.origin.y
    let visibleMaxY = visibleRect.origin.y + visibleRect.height

    // Use getLine(atPosition:) to find starting line
    let lineStorage = layoutManager.lineStorage
    let startLinePosition = lineStorage.getLine(atPosition: max(visibleMinY, 0))
    let startIndex = startLinePosition?.index ?? 0

    // Draw line numbers for visible lines
    for lineIndex in startIndex..<lineCount {
      guard let linePosition = lineStorage.getLine(atIndex: lineIndex) else { continue }

      let lineY = linePosition.yPos
      let lineHeight = linePosition.height

      // Stop if we've passed the visible area
      if lineY > visibleMaxY {
        break
      }

      // Convert text view Y to ruler view Y (ruler view is in scroll view coordinates)
      let drawY = lineY - visibleMinY + convert(NSPoint.zero, from: clipView).y
      let numberString = "\(lineIndex + 1)"
      let drawRect = NSRect(
        x: leadingPadding,
        y: drawY,
        width: ruleThickness - leadingPadding - trailingPadding,
        height: lineHeight
      )
      numberString.draw(in: drawRect, withAttributes: attributes)
    }
  }

  // MARK: - Width Management

  func updateGutterWidth() {
    guard let layoutManager = textView?.layoutManager else { return }
    let lineCount = max(layoutManager.lineCount, 1)
    let newThickness = computeThickness(for: lineCount)
    if ruleThickness != newThickness {
      ruleThickness = newThickness
    }
    needsDisplay = true
  }

  private func computeThickness(for lineCount: Int) -> CGFloat {
    let digitCount = max(String(lineCount).count, 2)
    let sampleString = String(repeating: "8", count: digitCount) as NSString
    let size = sampleString.size(withAttributes: [.font: gutterFont])
    return ceil(size.width + leadingPadding + trailingPadding)
  }
}
