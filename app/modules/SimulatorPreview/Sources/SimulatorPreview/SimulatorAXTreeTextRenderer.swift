import CoreGraphics
import Foundation

/// Renders a `SimulatorAXElement` tree as compact indented text for agents —
/// the `agenthub_simulator_describe_ui` MCP tool's payload. Bounded by depth
/// and element count so a pathological tree can't flood a tool result, with
/// explicit truncation markers (silent truncation would read as "that's the
/// whole screen").
public enum SimulatorAXTreeTextRenderer {
  public static func render(
    _ root: SimulatorAXElement,
    maxDepth: Int = 20,
    maxElements: Int = 500
  ) -> String {
    var lines: [String] = []
    var rendered = 0
    var truncatedByDepth = false
    var truncatedByCount = false

    func visit(_ element: SimulatorAXElement, depth: Int) {
      guard rendered < maxElements else {
        truncatedByCount = true
        return
      }
      lines.append(line(for: element, depth: depth))
      rendered += 1

      guard depth < maxDepth else {
        if !element.children.isEmpty { truncatedByDepth = true }
        return
      }
      for child in element.children {
        visit(child, depth: depth + 1)
      }
    }

    visit(root, depth: 0)

    if truncatedByCount {
      lines.append("… truncated: more than \(maxElements) elements")
    }
    if truncatedByDepth {
      lines.append("… truncated: subtrees deeper than \(maxDepth) levels omitted")
    }
    return lines.joined(separator: "\n")
  }

  /// One element per line: role, label/identifier, value, and its frame in
  /// device points — `Button "Like" id=likeButton value=1 (12, 40, 44x44)`.
  static func line(for element: SimulatorAXElement, depth: Int) -> String {
    var parts: [String] = [element.summary]
    if let identifier = element.identifier, !identifier.isEmpty,
       // `summary` already shows the identifier when there is no label.
       !(element.label ?? "").isEmpty
    {
      parts.append("id=\(identifier)")
    }
    if let value = element.value, !value.isEmpty {
      parts.append("value=\(String(value.prefix(60)))")
    }
    parts.append(frameDescription(element.frame))
    return String(repeating: "  ", count: depth) + parts.joined(separator: " ")
  }

  public static func frameDescription(_ frame: CGRect) -> String {
    "(\(Int(frame.minX)), \(Int(frame.minY)), \(Int(frame.width))x\(Int(frame.height)))"
  }
}
