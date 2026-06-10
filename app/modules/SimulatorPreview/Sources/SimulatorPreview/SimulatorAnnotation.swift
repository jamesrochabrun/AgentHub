import CoreGraphics
import Foundation

/// The accessibility element a pin is attached to, captured at annotation time
/// from the simulator's accessibility tree (`SimulatorAXInspector`).
public struct SimulatorAnnotationTarget: Equatable, Sendable {
  /// Role with the "AX" prefix stripped, e.g. "Button".
  public let role: String?
  public let label: String?
  public let identifier: String?
  /// Element frame in device points (top-left origin).
  public let frame: CGRect
  /// When the screen has several elements with this exact summary, the
  /// 1-based position of this one among them (top to bottom, then left to
  /// right) and the total count — identity alone is ambiguous then.
  public let matchIndex: Int?
  public let matchCount: Int?

  public init(
    role: String?, label: String?, identifier: String?, frame: CGRect,
    matchIndex: Int? = nil, matchCount: Int? = nil
  ) {
    self.role = role
    self.label = label
    self.identifier = identifier
    self.frame = frame
    self.matchIndex = matchIndex
    self.matchCount = matchCount
  }

  public init(element: SimulatorAXElement) {
    self.init(
      role: element.role, label: element.label,
      identifier: element.identifier, frame: element.frame)
  }

  /// Captures the element and, when `tree` contains other elements with the
  /// same summary, its ordinal among them so the prompt stays unambiguous.
  public init(element: SimulatorAXElement, tree: SimulatorAXElement?) {
    var index: Int? = nil
    var count: Int? = nil
    if let tree {
      let matches = tree.flattened().filter {
        $0.summary == element.summary && $0.role == element.role
      }
      if matches.count > 1 {
        let ordered = matches.sorted {
          ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
        }
        if let position = ordered.firstIndex(of: element) {
          index = position + 1
          count = matches.count
        }
      }
    }
    self.init(
      role: element.role, label: element.label,
      identifier: element.identifier, frame: element.frame,
      matchIndex: index, matchCount: count)
  }

  /// A short human-readable summary, e.g. `Button "Like"`.
  public var summary: String {
    var parts: [String] = [role ?? "Element"]
    if let label, !label.isEmpty {
      parts.append("\"\(label)\"")
    } else if let identifier, !identifier.isEmpty {
      parts.append("`\(identifier)`")
    }
    return parts.joined(separator: " ")
  }

  /// Whether the element can be found in source by name alone (label or
  /// accessibility identifier). Identity-less elements fall back to geometry.
  public var hasIdentity: Bool {
    (label?.isEmpty == false) || (identifier?.isEmpty == false)
  }
}

/// A numbered feedback pin the user dropped on the live simulator preview.
///
/// Positions are normalized to the device framebuffer (0...1, top-left
/// origin) so they stay valid across view resizes and map directly onto a
/// device-resolution screenshot. When the accessibility tree was available,
/// `target` carries the element the pin landed on.
public struct SimulatorAnnotation: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let normalizedX: Double
  public let normalizedY: Double
  /// The user's instruction for this spot ("move this to be top aligned").
  public var text: String
  /// The accessibility element under the pin, when element data was available.
  public var target: SimulatorAnnotationTarget?

  public init(
    id: UUID = UUID(),
    normalizedX: Double,
    normalizedY: Double,
    text: String,
    target: SimulatorAnnotationTarget? = nil
  ) {
    self.id = id
    self.normalizedX = min(max(normalizedX, 0), 1)
    self.normalizedY = min(max(normalizedY, 0), 1)
    self.text = text
    self.target = target
  }
}

/// Composes the agent-facing prompt for a batch of simulator annotations.
///
/// The wrapper carries no intent of its own — the user's note per pin is the
/// instruction (it may be a question, not a change request), and the stamped
/// screenshot is offered as optional context, never as a command to read it.
public enum SimulatorAnnotationPromptBuilder {
  /// - Parameters:
  ///   - screenPointSize: the device screen size in points (the accessibility
  ///     root frame), included so element frames have a reference.
  ///   - screenshotPixelSize: the device framebuffer size in pixels, when
  ///     known, so pin positions can be given as concrete pixel coordinates.
  ///   - screenshotPath: path to a screenshot with the numbered pins stamped
  ///     on it, when one was captured.
  public static func prompt(
    annotations: [SimulatorAnnotation],
    deviceName: String?,
    screenPointSize: CGSize? = nil,
    screenshotPixelSize: CGSize?,
    screenshotPath: String?
  ) -> String {
    guard !annotations.isEmpty else { return "" }
    let device = deviceName.map { " (\($0))" } ?? ""

    // Single pin: one compact sentence, no list scaffolding.
    if annotations.count == 1, let annotation = annotations.first {
      let text = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let subject = annotation.target != nil
        ? "the \(descriptor(for: annotation, screenPointSize: screenPointSize, screenshotPixelSize: screenshotPixelSize))"
        : descriptor(for: annotation, screenPointSize: screenPointSize, screenshotPixelSize: screenshotPixelSize)
      var lines = ["In the iOS app running in the simulator preview\(device), I pointed at \(subject) and noted: \(text)"]
      if let screenshotPath {
        lines.append("")
        lines.append("(If you need visual context, a screenshot with the pin marked is saved at: \(screenshotPath))")
      }
      return lines.joined(separator: "\n")
    }

    var lines = [
      "I annotated the iOS app running in the simulator preview\(device). Each numbered pin marks an element in the UI:",
      "",
    ]
    for (index, annotation) in annotations.enumerated() {
      let text = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
      var subject = descriptor(
        for: annotation, screenPointSize: screenPointSize,
        screenshotPixelSize: screenshotPixelSize)
      if annotation.target == nil {
        subject = "At " + subject
      }
      lines.append("\(index + 1). \(subject): \(text)")
    }
    if let screenshotPath {
      lines.append("")
      lines.append("(If you need visual context, a screenshot with the numbered pins drawn on it is saved at: \(screenshotPath))")
    }
    return lines.joined(separator: "\n")
  }

  /// The pin's subject, without a leading article: `Button "Exit" (...)`,
  /// `Image — frame (...) pt ...`, or a positional fallback
  /// (`50.0% from the left, ...`) when no element data was captured.
  private static func descriptor(
    for annotation: SimulatorAnnotation,
    screenPointSize: CGSize?,
    screenshotPixelSize: CGSize?
  ) -> String {
    if let target = annotation.target {
      var descriptor = target.summary
      if target.hasIdentity {
        if let identifier = target.identifier, !identifier.isEmpty, target.label != nil {
          descriptor += " (identifier `\(identifier)`)"
        }
        // Identity alone is ambiguous when the screen repeats it — add the
        // ordinal and frame only then.
        if (target.matchCount ?? 0) > 1,
          let matchIndex = target.matchIndex, let matchCount = target.matchCount {
          descriptor += " (the \(ordinal(matchIndex)) of \(matchCount) with this label, top to bottom)"
          descriptor += frameDescriptor(target.frame, screenPointSize: screenPointSize)
        }
      } else {
        // Anonymous element: its frame is the only handle we have.
        descriptor += frameDescriptor(target.frame, screenPointSize: screenPointSize)
      }
      return descriptor
    }

    let px = String(format: "%.1f%%", annotation.normalizedX * 100)
    let py = String(format: "%.1f%%", annotation.normalizedY * 100)
    var location = "\(px) from the left, \(py) from the top"
    if let size = screenshotPixelSize, size.width > 0, size.height > 0 {
      let x = Int((annotation.normalizedX * size.width).rounded())
      let y = Int((annotation.normalizedY * size.height).rounded())
      location += " (pixel \(x), \(y) in the \(Int(size.width))×\(Int(size.height)) screenshot)"
    }
    return location
  }

  private static func frameDescriptor(_ frame: CGRect, screenPointSize: CGSize?) -> String {
    var text = String(
      format: " — frame (x: %.0f, y: %.0f, w: %.0f, h: %.0f) pt",
      frame.minX, frame.minY, frame.width, frame.height)
    if let screenPointSize, screenPointSize.width > 0, screenPointSize.height > 0 {
      text += " on the \(Int(screenPointSize.width))×\(Int(screenPointSize.height)) pt screen"
    }
    return text
  }

  private static func ordinal(_ value: Int) -> String {
    let suffix: String
    switch (value % 100, value % 10) {
    case (11...13, _): suffix = "th"
    case (_, 1): suffix = "st"
    case (_, 2): suffix = "nd"
    case (_, 3): suffix = "rd"
    default: suffix = "th"
    }
    return "\(value)\(suffix)"
  }
}
