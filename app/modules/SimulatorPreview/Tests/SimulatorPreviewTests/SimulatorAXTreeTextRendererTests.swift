import CoreGraphics
import Foundation
import Testing

@testable import SimulatorPreview

@Suite("SimulatorAXTreeTextRenderer")
struct SimulatorAXTreeTextRendererTests {
  private func element(
    role: String? = "Button",
    label: String? = nil,
    identifier: String? = nil,
    value: String? = nil,
    frame: CGRect = CGRect(x: 10, y: 20, width: 44, height: 44),
    children: [SimulatorAXElement] = []
  ) -> SimulatorAXElement {
    SimulatorAXElement(
      role: role, label: label, identifier: identifier, value: value,
      frame: frame, children: children
    )
  }

  @Test("Renders nested elements with indentation, identity, and frames")
  func rendersNestedTree() {
    let tree = element(
      role: "Application",
      label: "MyApp",
      frame: CGRect(x: 0, y: 0, width: 390, height: 844),
      children: [
        element(role: "Button", label: "Like", identifier: "likeButton", value: "1"),
        element(role: "StaticText", identifier: "subtitle"),
      ]
    )

    let text = SimulatorAXTreeTextRenderer.render(tree)
    let lines = text.split(separator: "\n").map(String.init)

    #expect(lines[0] == "Application \"MyApp\" (0, 0, 390x844)")
    #expect(lines[1] == "  Button \"Like\" id=likeButton value=1 (10, 20, 44x44)")
    #expect(lines[2] == "  StaticText `subtitle` (10, 20, 44x44)")
    #expect(lines.count == 3)
  }

  @Test("Element cap truncates with an explicit marker")
  func elementCapTruncates() {
    let children = (0..<10).map { index in
      element(role: "Cell", label: "Row \(index)")
    }
    let tree = element(role: "Table", label: "List", children: children)

    let text = SimulatorAXTreeTextRenderer.render(tree, maxElements: 4)
    let lines = text.split(separator: "\n").map(String.init)

    #expect(lines.count == 5)
    #expect(lines.last == "… truncated: more than 4 elements")
  }

  @Test("Depth cap omits deeper subtrees with an explicit marker")
  func depthCapTruncates() {
    let deep = element(
      role: "Group", label: "L0",
      children: [element(
        role: "Group", label: "L1",
        children: [element(role: "Group", label: "L2")]
      )]
    )

    let text = SimulatorAXTreeTextRenderer.render(deep, maxDepth: 1)

    #expect(text.contains("\"L1\""))
    #expect(!text.contains("\"L2\""))
    #expect(text.contains("truncated: subtrees deeper than 1"))
  }

  @Test("Long values are clipped to keep lines compact")
  func longValuesClipped() {
    let long = String(repeating: "x", count: 100)
    let line = SimulatorAXTreeTextRenderer.line(
      for: element(role: "TextField", label: "Notes", value: long),
      depth: 0
    )
    #expect(line.contains("value=\(String(repeating: "x", count: 60))"))
    #expect(!line.contains(String(repeating: "x", count: 61)))
  }
}
