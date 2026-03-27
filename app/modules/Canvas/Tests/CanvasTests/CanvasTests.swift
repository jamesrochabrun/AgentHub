import CoreGraphics
import Foundation
import Testing
@testable import Canvas

/// Shared test fixtures for creating `ElementInspectorData` instances.
enum TestFixtures {

  /// Creates a fully populated button element with sensible defaults.
  static func makeButton(
    id: UUID = UUID(),
    tagName: String = "BUTTON",
    elementId: String = "submit-btn",
    className: String = "btn primary",
    textContent: String = "Submit",
    outerHTML: String = "<button id=\"submit-btn\" class=\"btn primary\">Submit</button>",
    cssSelector: String = "form > button.btn.primary",
    computedStyles: [String: String] = [
      "color": "rgb(255, 255, 255)",
      "backgroundColor": "rgb(37, 99, 235)",
      "fontSize": "16px",
      "padding": "8px 16px",
      "borderRadius": "6px",
      "display": "inline-flex",
    ],
    boundingRect: CGRect = CGRect(x: 100, y: 200, width: 120, height: 40)
  ) -> ElementInspectorData {
    ElementInspectorData(
      id: id,
      tagName: tagName,
      elementId: elementId,
      className: className,
      textContent: textContent,
      outerHTML: outerHTML,
      cssSelector: cssSelector,
      computedStyles: computedStyles,
      boundingRect: boundingRect
    )
  }

  /// Creates a minimal div element with empty/zero values.
  static func makeMinimalDiv() -> ElementInspectorData {
    ElementInspectorData(
      tagName: "DIV",
      elementId: "",
      className: "",
      textContent: "",
      outerHTML: "",
      cssSelector: "div",
      computedStyles: [:],
      boundingRect: .zero
    )
  }
}
