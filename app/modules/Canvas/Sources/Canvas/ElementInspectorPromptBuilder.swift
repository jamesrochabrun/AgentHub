//
//  ElementInspectorPromptBuilder.swift
//  WebInspector
//
//  Constructs the structured prompt sent to Claude after the user
//  selects an element and describes their desired change.
//

import Foundation

/// Builds a structured prompt from inspected element data and a user instruction.
public enum ElementInspectorPromptBuilder {

  /// Constructs the prompt string sent to the terminal session.
  public static func buildPrompt(
    element: ElementInspectorData,
    instruction: String
  ) -> String {
    var lines = [
      "I'm looking at a web element in the live preview:",
      "",
      "**Element**: \(element.outerHTML.isEmpty ? element.tagName.lowercased() : element.outerHTML)",
      "**CSS Selector**: \(element.cssSelector)",
    ]

    let relevantStyles = [
      "background-color", "backgroundColor", "color", "font-size", "fontSize",
      "padding", "border-radius", "borderRadius", "width", "height", "display",
    ]
    let presentStyles = relevantStyles.compactMap { key -> String? in
      guard let value = element.computedStyles[key], !value.isEmpty else { return nil }
      return "  \(key): \(value)"
    }
    if !presentStyles.isEmpty {
      lines.append("**Computed Styles**:")
      lines.append(contentsOf: presentStyles)
    }

    lines.append("")
    lines.append("User request: \(instruction)")
    lines.append("")
    lines.append("Please modify the source code to make this change.")

    return lines.joined(separator: "\n")
  }

  /// Constructs a context-only prompt (no user instruction).
  ///
  /// Used in context mode where the element data is sent immediately
  /// without the user typing an instruction.
  public static func buildContextPrompt(
    element: ElementInspectorData
  ) -> String {
    var lines = [
      "Selected web element context:",
      "",
      "**Element**: \(element.outerHTML.isEmpty ? element.tagName.lowercased() : element.outerHTML)",
      "**CSS Selector**: \(element.cssSelector)",
    ]

    let relevantStyles = [
      "background-color", "backgroundColor", "color", "font-size", "fontSize",
      "padding", "border-radius", "borderRadius", "width", "height", "display",
    ]
    let presentStyles = relevantStyles.compactMap { key -> String? in
      guard let value = element.computedStyles[key], !value.isEmpty else { return nil }
      return "  \(key): \(value)"
    }
    if !presentStyles.isEmpty {
      lines.append("**Computed Styles**:")
      lines.append(contentsOf: presentStyles)
    }

    return lines.joined(separator: "\n")
  }
}
