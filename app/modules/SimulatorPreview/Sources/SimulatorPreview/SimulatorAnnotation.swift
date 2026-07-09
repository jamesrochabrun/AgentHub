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

/// View-facing placement for a simulator annotation pin.
public struct SimulatorAnnotationPinPlacement: Equatable, Sendable {
  /// The resolved point before viewport clamping. Values can be outside 0...1
  /// when the target element has moved beyond the visible screen.
  public let normalizedPoint: CGPoint
  /// The point clamped to the visible simulator viewport.
  public let viewportNormalizedPoint: CGPoint

  public var isPinnedToViewportEdge: Bool {
    normalizedPoint != viewportNormalizedPoint
  }

  public init(normalizedPoint: CGPoint) {
    self.normalizedPoint = normalizedPoint
    self.viewportNormalizedPoint = CGPoint(
      x: min(max(normalizedPoint.x, 0), 1),
      y: min(max(normalizedPoint.y, 0), 1))
  }
}

/// Resolves where an annotation pin should appear against the current AX tree.
public enum SimulatorAnnotationPinLocator {
  /// Returns where the pin should render, or `nil` when the pin is bound to an
  /// element that has scrolled out of the captured accessibility tree — the
  /// caller hides those rather than stranding them at a stale position.
  public static func placement(
    for annotation: SimulatorAnnotation,
    in tree: SimulatorAXElement?
  ) -> SimulatorAnnotationPinPlacement? {
    let fallback = CGPoint(x: annotation.normalizedX, y: annotation.normalizedY)
    // No element binding, or no tree to resolve against yet: keep the pin at its
    // original drop point (positional pins never move).
    guard let target = annotation.target,
          let tree,
          tree.frame.width > 0,
          tree.frame.height > 0
    else {
      return SimulatorAnnotationPinPlacement(normalizedPoint: fallback)
    }
    // The bound element is gone from the tree — it scrolled off the visible
    // screen. Signal "lost" so the overlay can hide the pin.
    guard let currentElement = element(matching: target, in: tree) else {
      return nil
    }

    let originalPoint = CGPoint(
      x: tree.frame.minX + annotation.normalizedX * tree.frame.width,
      y: tree.frame.minY + annotation.normalizedY * tree.frame.height)
    let relativeX = relativePosition(
      originalPoint.x, start: target.frame.minX, length: target.frame.width)
    let relativeY = relativePosition(
      originalPoint.y, start: target.frame.minY, length: target.frame.height)
    let currentPoint = CGPoint(
      x: currentElement.frame.minX + currentElement.frame.width * relativeX,
      y: currentElement.frame.minY + currentElement.frame.height * relativeY)
    return SimulatorAnnotationPinPlacement(
      normalizedPoint: CGPoint(
        x: (currentPoint.x - tree.frame.minX) / tree.frame.width,
        y: (currentPoint.y - tree.frame.minY) / tree.frame.height))
  }

  private static func relativePosition(_ value: Double, start: Double, length: Double) -> Double {
    guard length > 0 else { return 0.5 }
    return min(max((value - start) / length, 0), 1)
  }

  private static func element(
    matching target: SimulatorAnnotationTarget,
    in tree: SimulatorAXElement
  ) -> SimulatorAXElement? {
    let elements = Array(tree.flattened().dropFirst())

    if let identifier = target.identifier, !identifier.isEmpty {
      let matches = elements.filter {
        $0.identifier == identifier && $0.role == target.role
      }
      return disambiguated(matches: matches, target: target)
    }

    if let label = target.label, !label.isEmpty {
      let matches = elements.filter {
        $0.label == label && $0.role == target.role
      }
      return disambiguated(matches: matches, target: target)
    }

    let matches = elements.filter {
      $0.summary == target.summary && $0.role == target.role
    }
    return disambiguated(matches: matches, target: target)
  }

  private static func disambiguated(
    matches: [SimulatorAXElement],
    target: SimulatorAnnotationTarget
  ) -> SimulatorAXElement? {
    guard !matches.isEmpty else { return nil }
    let ordered = matches.sorted {
      ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
    }
    if let matchIndex = target.matchIndex,
       matchIndex > 0,
       matchIndex <= ordered.count {
      return ordered[matchIndex - 1]
    }
    return ordered.count == 1 ? ordered[0] : nearest(to: target.frame, in: ordered)
  }

  private static func nearest(
    to frame: CGRect,
    in elements: [SimulatorAXElement]
  ) -> SimulatorAXElement? {
    elements.min {
      distanceSquared($0.frame.center, frame.center) < distanceSquared($1.frame.center, frame.center)
    }
  }

  private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return dx * dx + dy * dy
  }
}

private extension CGRect {
  var center: CGPoint {
    CGPoint(x: midX, y: midY)
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
      lines.append("")
      lines.append(verificationFooter)
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
    lines.append("")
    lines.append(verificationFooter)
    return lines.joined(separator: "\n")
  }

  /// Process guidance only — conditional on the agent choosing to change
  /// code, so the user's note stays the sole instruction. Exists because a
  /// bare `xcodebuild build` "validation" neither updates nor verifies the
  /// app the user is looking at.
  static let verificationFooter = """
    If you make code changes in response, verify them in the live simulator with XcodeBuildMCP \
    build/run and screenshot or UI inspection tools before declaring the change done.
    """

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
