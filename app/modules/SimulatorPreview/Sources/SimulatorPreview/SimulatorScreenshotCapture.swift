import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One-shot screenshot of a booted simulator with annotation pins stamped on
/// it, written to a temp file so the agent can read it alongside the prompt.
///
/// Capture uses only public `simctl io screenshot` (same invocation as the
/// `ScreenshotPoller` fallback). Writing to disk happens solely on an explicit
/// user action — sending annotation feedback — never as part of streaming.
public enum SimulatorScreenshotCapture {
  /// Captures the device's screen, stamps the numbered pins, and writes a PNG
  /// into a private temp directory. Returns nil if any step fails; callers
  /// should still send their prompt without the screenshot in that case.
  public static func writeAnnotatedScreenshot(
    udid: String,
    annotations: [SimulatorAnnotation]
  ) async -> URL? {
    let captured = await capturePNGData(udid: udid)
    guard let captured,
      let source = CGImageSourceCreateWithData(captured as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let annotated = annotatedPNGData(image: image, annotations: annotations)
    else { return nil }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubSimulatorAnnotations", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("annotated-\(UUID().uuidString).png")
      try annotated.write(to: url)
      return url
    } catch {
      return nil
    }
  }

  /// Raw PNG screenshot via `xcrun simctl io <udid> screenshot --type=png -`.
  public static func capturePNGData(udid: String) async -> Data? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: capturePNGDataSync(udid: udid))
      }
    }
  }

  private static func capturePNGDataSync(udid: String) -> Data? {
    // Newer simctl no longer writes to stdout ("-" is treated as a literal
    // filename), so capture into a temp file and read it back.
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-sim-shot-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", tempURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0, let data = try? Data(contentsOf: tempURL),
      !data.isEmpty
    else { return nil }
    return data
  }

  /// Stamps numbered pins (filled circle + index) onto the image at each
  /// annotation's normalized position and re-encodes as PNG.
  public static func annotatedPNGData(
    image: CGImage,
    annotations: [SimulatorAnnotation]
  ) -> Data? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let radius = max(18, 0.018 * CGFloat(width))
    for (index, annotation) in annotations.enumerated() {
      // CGContext origin is bottom-left; annotations are top-left normalized.
      let center = CGPoint(
        x: CGFloat(annotation.normalizedX) * CGFloat(width),
        y: CGFloat(height) - CGFloat(annotation.normalizedY) * CGFloat(height)
      )
      drawPin(number: index + 1, at: center, radius: radius, in: context)
    }

    guard let stamped = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, stamped, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  private static func drawPin(number: Int, at center: CGPoint, radius: CGFloat, in context: CGContext) {
    let circleRect = CGRect(
      x: center.x - radius, y: center.y - radius,
      width: radius * 2, height: radius * 2)

    context.setFillColor(CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0))
    context.fillEllipse(in: circleRect)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(max(2, radius * 0.14))
    context.strokeEllipse(in: circleRect)

    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, radius * 1.05, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String):
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ]
    let attributed = NSAttributedString(string: "\(number)", attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(
      x: center.x - bounds.midX,
      y: center.y - bounds.midY
    )
    CTLineDraw(line, context)
  }
}
