import CoreGraphics
import XCTest

@testable import SimulatorPreview

final class SimulatorAnnotationTests: XCTestCase {
  // MARK: - Model

  func testAnnotationClampsNormalizedCoordinates() {
    let annotation = SimulatorAnnotation(normalizedX: -0.5, normalizedY: 1.7, text: "x")
    XCTAssertEqual(annotation.normalizedX, 0)
    XCTAssertEqual(annotation.normalizedY, 1)
  }

  func testPinPlacementTracksResolvedTargetFrame() throws {
    let originalElement = SimulatorAXElement(
      role: "Button", label: "Buy", identifier: "buyButton", value: nil,
      frame: CGRect(x: 100, y: 200, width: 100, height: 50), children: [])
    let originalTree = SimulatorAXElement(
      role: "Application", label: nil, identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 400, height: 800),
      children: [originalElement])
    let refreshedTree = SimulatorAXElement(
      role: "Application", label: nil, identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 400, height: 800),
      children: [
        SimulatorAXElement(
          role: "Button", label: "Buy", identifier: "buyButton", value: nil,
          frame: CGRect(x: 100, y: 80, width: 100, height: 50), children: [])
      ])
    let annotation = SimulatorAnnotation(
      normalizedX: 125.0 / 400.0,
      normalizedY: 220.0 / 800.0,
      text: "align this",
      target: SimulatorAnnotationTarget(element: originalElement, tree: originalTree))

    let placement = try XCTUnwrap(
      SimulatorAnnotationPinLocator.placement(for: annotation, in: refreshedTree))

    XCTAssertEqual(placement.normalizedPoint.x, 125.0 / 400.0, accuracy: 0.0001)
    XCTAssertEqual(placement.normalizedPoint.y, 100.0 / 800.0, accuracy: 0.0001)
    XCTAssertFalse(placement.isPinnedToViewportEdge)
  }

  func testPinPlacementClampsResolvedTargetBeyondViewport() throws {
    let originalElement = SimulatorAXElement(
      role: "Button", label: "Buy", identifier: "buyButton", value: nil,
      frame: CGRect(x: 100, y: 200, width: 100, height: 50), children: [])
    let tree = SimulatorAXElement(
      role: "Application", label: nil, identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 400, height: 800),
      children: [
        SimulatorAXElement(
          role: "Button", label: "Buy", identifier: "buyButton", value: nil,
          frame: CGRect(x: 100, y: -120, width: 100, height: 50), children: [])
      ])
    let annotation = SimulatorAnnotation(
      normalizedX: 125.0 / 400.0,
      normalizedY: 220.0 / 800.0,
      text: "align this",
      target: SimulatorAnnotationTarget(element: originalElement))

    let placement = try XCTUnwrap(
      SimulatorAnnotationPinLocator.placement(for: annotation, in: tree))

    XCTAssertLessThan(placement.normalizedPoint.y, 0)
    XCTAssertEqual(placement.viewportNormalizedPoint.y, 0)
    XCTAssertTrue(placement.isPinnedToViewportEdge)
  }

  func testPinPlacementIsNilWhenBoundElementScrolledOffScreen() {
    // An element-bound pin whose target is no longer in the refreshed tree:
    // the element scrolled out of view, so the pin is hidden (nil), not
    // stranded at its original drop position.
    let annotation = SimulatorAnnotation(
      normalizedX: 0.25,
      normalizedY: 0.75,
      text: "align this",
      target: SimulatorAnnotationTarget(
        role: "Button", label: "Missing", identifier: "missingButton",
        frame: CGRect(x: 100, y: 200, width: 100, height: 50)))
    let tree = SimulatorAXElement(
      role: "Application", label: nil, identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 400, height: 800),
      children: [])

    XCTAssertNil(SimulatorAnnotationPinLocator.placement(for: annotation, in: tree))
  }

  func testPinPlacementFallsBackForPositionalPinWithoutTarget() {
    // A pin with no element binding (positional fallback) always renders at its
    // drop point — it is never hidden.
    let annotation = SimulatorAnnotation(normalizedX: 0.25, normalizedY: 0.75, text: "align this")
    let tree = SimulatorAXElement(
      role: "Application", label: nil, identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 400, height: 800),
      children: [])

    let placement = SimulatorAnnotationPinLocator.placement(for: annotation, in: tree)

    XCTAssertEqual(placement?.normalizedPoint.x, 0.25)
    XCTAssertEqual(placement?.normalizedPoint.y, 0.75)
    XCTAssertEqual(placement?.isPinnedToViewportEdge, false)
  }

  // MARK: - Prompt builder

  func testPromptIsEmptyWithoutAnnotations() {
    XCTAssertEqual(
      SimulatorAnnotationPromptBuilder.prompt(
        annotations: [], deviceName: "iPhone 17 Pro",
        screenshotPixelSize: nil, screenshotPath: nil),
      "")
  }

  func testPromptListsNumberedPinsWithPercentAndPixelCoordinates() {
    let annotations = [
      SimulatorAnnotation(normalizedX: 0.5, normalizedY: 0.25, text: "move this to be top aligned"),
      SimulatorAnnotation(normalizedX: 0.1, normalizedY: 0.9, text: "  make this bigger \n"),
    ]
    let prompt = SimulatorAnnotationPromptBuilder.prompt(
      annotations: annotations,
      deviceName: "iPhone 17 Pro",
      screenshotPixelSize: CGSize(width: 1000, height: 2000),
      screenshotPath: "/tmp/pins.png")

    XCTAssertTrue(prompt.contains("(iPhone 17 Pro)"))
    XCTAssertTrue(
      prompt.contains(
        "1. At 50.0% from the left, 25.0% from the top (pixel 500, 500 in the 1000×2000 screenshot): move this to be top aligned"
      ))
    XCTAssertTrue(prompt.contains("2. At 10.0% from the left, 90.0% from the top"))
    // Instruction text is trimmed.
    XCTAssertTrue(prompt.contains(": make this bigger\n") || prompt.hasSuffix(": make this bigger"))
    // The screenshot is optional context, not a command to read it.
    XCTAssertTrue(prompt.contains("(If you need visual context"))
    XCTAssertTrue(prompt.contains("/tmp/pins.png"))
    XCTAssertFalse(prompt.lowercased().contains("make the requested changes"))
  }

  func testPromptDescribesIdentifiedElementsWithoutAnyCoordinates() {
    let target = SimulatorAnnotationTarget(
      role: "Button", label: "Safari", identifier: "safariButton",
      frame: CGRect(x: 123, y: 771, width: 68, height: 68))
    let prompt = SimulatorAnnotationPromptBuilder.prompt(
      annotations: [
        SimulatorAnnotation(normalizedX: 0.39, normalizedY: 0.92, text: "move this to be top aligned", target: target)
      ],
      deviceName: "iPhone 17 Pro",
      screenPointSize: CGSize(width: 402, height: 874),
      screenshotPixelSize: CGSize(width: 1206, height: 2622),
      screenshotPath: nil)

    // A single pin is one compact sentence carrying only the user's words.
    XCTAssertTrue(
      prompt.contains(
        "I pointed at the Button \"Safari\" (identifier `safariButton`) and noted: move this to be top aligned"
      ), prompt)
    // Identified elements carry no geometry of any kind, and the wrapper adds
    // no intent of its own.
    XCTAssertFalse(prompt.contains("frame ("))
    XCTAssertFalse(prompt.contains("pt screen"))
    XCTAssertFalse(prompt.contains("% from the left"))
    XCTAssertFalse(prompt.lowercased().contains("make the requested changes"))
  }

  func testDuplicateLabelsGetOrdinalAndFrame() {
    let topExit = SimulatorAXElement(
      role: "Button", label: "Exit", identifier: nil, value: nil,
      frame: CGRect(x: 70, y: 120, width: 262, height: 50), children: [])
    let bottomExit = SimulatorAXElement(
      role: "Button", label: "Exit", identifier: nil, value: nil,
      frame: CGRect(x: 70, y: 493, width: 262, height: 50), children: [])
    let tree = SimulatorAXElement(
      role: "Application", label: nil, identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 402, height: 874),
      children: [topExit, bottomExit])

    let target = SimulatorAnnotationTarget(element: bottomExit, tree: tree)
    XCTAssertEqual(target.matchIndex, 2)
    XCTAssertEqual(target.matchCount, 2)

    let prompt = SimulatorAnnotationPromptBuilder.prompt(
      annotations: [
        SimulatorAnnotation(normalizedX: 0.5, normalizedY: 0.6, text: "make this green", target: target)
      ],
      deviceName: nil,
      screenPointSize: CGSize(width: 402, height: 874),
      screenshotPixelSize: nil,
      screenshotPath: nil)
    XCTAssertTrue(
      prompt.contains(
        "I pointed at the Button \"Exit\" (the 2nd of 2 with this label, top to bottom) — frame (x: 70, y: 493, w: 262, h: 50) pt on the 402×874 pt screen and noted: make this green"
      ), prompt)

    // A unique element on the same screen still gets identity only.
    let unique = SimulatorAnnotationTarget(element: topExit, tree: nil)
    XCTAssertNil(unique.matchIndex)
  }

  func testPromptUsesFrameOnlyForAnonymousElements() {
    let target = SimulatorAnnotationTarget(
      role: "Image", label: nil, identifier: nil,
      frame: CGRect(x: 70, y: 493, width: 262, height: 50))
    let prompt = SimulatorAnnotationPromptBuilder.prompt(
      annotations: [
        SimulatorAnnotation(normalizedX: 0.5, normalizedY: 0.6, text: "make this green", target: target)
      ],
      deviceName: nil,
      screenPointSize: CGSize(width: 402, height: 874),
      screenshotPixelSize: nil,
      screenshotPath: nil)

    XCTAssertTrue(
      prompt.contains(
        "I pointed at the Image — frame (x: 70, y: 493, w: 262, h: 50) pt on the 402×874 pt screen and noted: make this green"
      ), prompt)
  }

  func testPromptOmitsPixelsAndScreenshotWhenUnknown() {
    let prompt = SimulatorAnnotationPromptBuilder.prompt(
      annotations: [SimulatorAnnotation(normalizedX: 0.5, normalizedY: 0.5, text: "fix")],
      deviceName: nil,
      screenshotPixelSize: nil,
      screenshotPath: nil)

    XCTAssertFalse(prompt.contains("pixel"))
    XCTAssertFalse(prompt.contains("saved at"))
    XCTAssertTrue(
      prompt.contains("I pointed at 50.0% from the left, 50.0% from the top and noted: fix"),
      prompt)
    XCTAssertFalse(prompt.lowercased().contains("make the requested changes"))
  }

  // MARK: - AX element model

  func testDeepestElementPrefersSmallestContainingFrame() {
    let icon = SimulatorAXElement(
      role: "Image", label: nil, identifier: "icon", value: nil,
      frame: CGRect(x: 10, y: 10, width: 20, height: 20), children: [])
    let button = SimulatorAXElement(
      role: "Button", label: "Like", identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 100, height: 40), children: [icon])
    let root = SimulatorAXElement(
      role: "Application", label: nil, identifier: nil, value: nil,
      frame: CGRect(x: 0, y: 0, width: 400, height: 800), children: [button])

    XCTAssertEqual(root.deepestElement(containing: CGPoint(x: 15, y: 15))?.identifier, "icon")
    XCTAssertEqual(root.deepestElement(containing: CGPoint(x: 80, y: 20))?.role, "Button")
    XCTAssertEqual(root.deepestElement(containing: CGPoint(x: 300, y: 700))?.role, "Application")
    XCTAssertNil(root.deepestElement(containing: CGPoint(x: 500, y: 900)))
    XCTAssertEqual(root.flattened().count, 3)
  }

  func testElementSummaryPrefersLabelThenIdentifier() {
    XCTAssertEqual(
      SimulatorAXElement(
        role: "Button", label: "Like", identifier: "likeBtn", value: nil,
        frame: .zero, children: []
      ).summary,
      "Button \"Like\"")
    XCTAssertEqual(
      SimulatorAXElement(
        role: "Button", label: nil, identifier: "likeBtn", value: nil,
        frame: .zero, children: []
      ).summary,
      "Button `likeBtn`")
    XCTAssertEqual(
      SimulatorAXElement(
        role: nil, label: nil, identifier: nil, value: nil,
        frame: .zero, children: []
      ).summary,
      "Element")
  }

  // MARK: - Inverse point mapping

  func testViewPointIsInverseOfNormalizedPoint() {
    let contentSize = CGSize(width: 1179, height: 2556)
    let viewSize = CGSize(width: 600, height: 800)
    let original = CGPoint(x: 320, y: 410)

    guard let normalized = SimulatorPointMapper.normalizedPoint(
      viewPoint: original, contentSize: contentSize, viewSize: viewSize)
    else { return XCTFail("expected point inside content rect") }

    guard let roundTripped = SimulatorPointMapper.viewPoint(
      normalizedX: normalized.x, normalizedY: normalized.y,
      contentSize: contentSize, viewSize: viewSize)
    else { return XCTFail("expected inverse mapping") }

    XCTAssertEqual(roundTripped.x, original.x, accuracy: 0.001)
    XCTAssertEqual(roundTripped.y, original.y, accuracy: 0.001)
  }

  func testViewPointCentersAndLetterboxes() {
    // 1:2 content in a square view → pillarboxed horizontally.
    let point = SimulatorPointMapper.viewPoint(
      normalizedX: 0.5, normalizedY: 0,
      contentSize: CGSize(width: 100, height: 200),
      viewSize: CGSize(width: 400, height: 400))
    XCTAssertEqual(point, CGPoint(x: 200, y: 0))
  }

  func testViewPointNilForDegenerateSizes() {
    XCTAssertNil(
      SimulatorPointMapper.viewPoint(
        normalizedX: 0.5, normalizedY: 0.5, contentSize: .zero,
        viewSize: CGSize(width: 100, height: 100)))
  }

  // MARK: - Screenshot stamping

  func testAnnotatedPNGDataStampsPins() throws {
    let image = try XCTUnwrap(Self.solidImage(width: 400, height: 800))
    let annotations = [SimulatorAnnotation(normalizedX: 0.5, normalizedY: 0.5, text: "here")]

    let data = try XCTUnwrap(
      SimulatorScreenshotCapture.annotatedPNGData(image: image, annotations: annotations))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let stamped = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

    XCTAssertEqual(stamped.width, 400)
    XCTAssertEqual(stamped.height, 800)
    // The pin center must differ from the black background.
    let center = try XCTUnwrap(Self.pixel(in: stamped, x: 200, y: 400))
    XCTAssertTrue(center.r > 10 || center.g > 10 || center.b > 10, "expected a stamped pin at the center")
    let corner = try XCTUnwrap(Self.pixel(in: stamped, x: 4, y: 4))
    XCTAssertTrue(corner.r < 10 && corner.g < 10 && corner.b < 10, "corner should stay untouched")
  }

  private static func solidImage(width: Int, height: Int) -> CGImage? {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    context?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage()
  }

  private static func pixel(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
    return (bytes[0], bytes[1], bytes[2])
  }
}
