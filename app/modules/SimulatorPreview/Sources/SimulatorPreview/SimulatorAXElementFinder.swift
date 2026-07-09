import CoreGraphics
import Foundation

/// Finds tappable elements in an accessibility tree by identity, so agents
/// can say "tap the Store button" instead of computing coordinates. Matching
/// is tiered — exact identifier/label, then case-insensitive, then substring —
/// and returns the whole best tier in document order so ambiguity can be
/// reported (and resolved with an ordinal) rather than guessed.
public enum SimulatorAXElementFinder {
  public static func matches(
    in root: SimulatorAXElement,
    label: String?,
    identifier: String?
  ) -> [SimulatorAXElement] {
    let label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (label?.isEmpty == false) || (identifier?.isEmpty == false) else { return [] }

    // Zero-size elements can't be tapped; drop them before matching.
    let candidates = root.flattened().filter { $0.frame.width > 0 && $0.frame.height > 0 }

    let exact = candidates.filter { element in
      matchesExactly(element: element, label: label, identifier: identifier)
    }
    if !exact.isEmpty { return exact }

    let caseInsensitive = candidates.filter { element in
      matchesCaseInsensitively(element: element, label: label, identifier: identifier)
    }
    if !caseInsensitive.isEmpty { return caseInsensitive }

    return candidates.filter { element in
      matchesBySubstring(element: element, label: label, identifier: identifier)
    }
  }

  private static func matchesExactly(
    element: SimulatorAXElement, label: String?, identifier: String?
  ) -> Bool {
    if let identifier, !identifier.isEmpty, element.identifier == identifier { return true }
    if let label, !label.isEmpty, element.label == label { return true }
    return false
  }

  private static func matchesCaseInsensitively(
    element: SimulatorAXElement, label: String?, identifier: String?
  ) -> Bool {
    if let identifier, !identifier.isEmpty,
       element.identifier?.caseInsensitiveCompare(identifier) == .orderedSame { return true }
    if let label, !label.isEmpty,
       element.label?.caseInsensitiveCompare(label) == .orderedSame { return true }
    return false
  }

  private static func matchesBySubstring(
    element: SimulatorAXElement, label: String?, identifier: String?
  ) -> Bool {
    if let identifier, !identifier.isEmpty,
       element.identifier?.range(of: identifier, options: .caseInsensitive) != nil { return true }
    if let label, !label.isEmpty,
       element.label?.range(of: label, options: .caseInsensitive) != nil { return true }
    return false
  }
}
