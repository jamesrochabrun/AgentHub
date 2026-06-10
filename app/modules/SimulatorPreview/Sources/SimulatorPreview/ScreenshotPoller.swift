import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// View-only capture fallback that polls `xcrun simctl io <udid> screenshot`.
///
/// Used when the private CoreSimulator frameworks are unavailable. Frame rate
/// is low (a few fps) and there is no input injection, but it relies only on
/// public, supported tooling.
final class ScreenshotPoller {
  private let udid: String
  private var onFrame: ((CVPixelBuffer, Int, Int) -> Void)?
  private let queue = DispatchQueue(label: "com.agenthub.simpreview.screenshot", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private let intervalMs: Int

  init(udid: String, intervalMs: Int = 500) {
    self.udid = udid
    self.intervalMs = intervalMs
  }

  func start(onFrame: @escaping (CVPixelBuffer, Int, Int) -> Void) {
    self.onFrame = onFrame
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))
    timer.setEventHandler { [weak self] in self?.capture() }
    timer.resume()
    self.timer = timer
  }

  func stop() {
    timer?.cancel()
    timer = nil
    onFrame = nil
  }

  private func capture() {
    // Newer simctl no longer writes to stdout ("-" is treated as a literal
    // filename), so capture into a temp file and read it back.
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-sim-poll-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", tempURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let data = try? Data(contentsOf: tempURL), !data.isEmpty
    else { return }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return }
    guard let pb = Self.pixelBuffer(from: image) else { return }
    onFrame?(pb, image.width, image.height)
  }

  static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    let width = image.width
    let height = image.height
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let buffer = pb else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: base, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
