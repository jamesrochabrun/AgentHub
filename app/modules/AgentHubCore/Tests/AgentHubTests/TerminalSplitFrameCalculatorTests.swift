import CoreGraphics
import Testing

@testable import AgentHubTerminalUI

@Suite("Terminal split frame calculator")
struct TerminalSplitFrameCalculatorTests {

  @Test("Nested vertical then horizontal splits fill the full rect")
  func nestedSplitsFillFullRect() {
    let tree = TerminalSplitLayoutTree<String>.split(
      axis: .vertical,
      children: [
        .pane("agent"),
        .split(axis: .horizontal, children: [.pane("shell-1"), .pane("shell-2")])
      ]
    )

    let frames = TerminalSplitFrameCalculator.frames(
      for: tree,
      in: CGRect(x: 0, y: 0, width: 900, height: 600),
      dividerSize: 1
    )

    #expect(frames["agent"] == CGRect(x: 0, y: 0, width: 449.5, height: 600))
    #expect(frames["shell-1"] == CGRect(x: 450.5, y: 0, width: 449.5, height: 299.5))
    #expect(frames["shell-2"] == CGRect(x: 450.5, y: 300.5, width: 449.5, height: 299.5))
  }
}
