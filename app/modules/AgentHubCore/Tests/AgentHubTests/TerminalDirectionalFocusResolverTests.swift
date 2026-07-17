import CoreGraphics
import Testing

@testable import AgentHubCore

@Suite("Terminal directional focus")
struct TerminalDirectionalFocusResolverTests {
  @Test("Directional focus works across a six-pane geometry")
  func sixPaneNavigation() {
    let frames = [
      "top-left": CGRect(x: 0, y: 0, width: 300, height: 200),
      "top-center": CGRect(x: 300, y: 0, width: 300, height: 200),
      "top-right": CGRect(x: 600, y: 0, width: 300, height: 200),
      "bottom-left": CGRect(x: 0, y: 200, width: 300, height: 200),
      "bottom-center": CGRect(x: 300, y: 200, width: 300, height: 200),
      "bottom-right": CGRect(x: 600, y: 200, width: 300, height: 200)
    ]

    #expect(
      TerminalDirectionalFocusResolver.target(
        from: "top-center",
        frames: frames,
        direction: .left
      ) == "top-left"
    )
    #expect(
      TerminalDirectionalFocusResolver.target(
        from: "top-center",
        frames: frames,
        direction: .right
      ) == "top-right"
    )
    #expect(
      TerminalDirectionalFocusResolver.target(
        from: "top-center",
        frames: frames,
        direction: .down
      ) == "bottom-center"
    )
    #expect(
      TerminalDirectionalFocusResolver.target(
        from: "bottom-right",
        frames: frames,
        direction: .up
      ) == "top-right"
    )
  }

  @Test("Focus prefers an overlapping pane over a diagonal pane")
  func overlapPreference() {
    let frames = [
      "current": CGRect(x: 0, y: 0, width: 300, height: 300),
      "overlap": CGRect(x: 320, y: 100, width: 300, height: 100),
      "diagonal": CGRect(x: 310, y: 400, width: 300, height: 100)
    ]

    #expect(
      TerminalDirectionalFocusResolver.target(
        from: "current",
        frames: frames,
        direction: .right
      ) == "overlap"
    )
  }
}
