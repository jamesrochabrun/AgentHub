import CoreVideo
import Foundation

/// Capture backend seam: both the CoreSimulator framebuffer tap and the
/// screenshot-polling fallback feed frames through this interface so the
/// session lifecycle can be unit tested with spies — tests never load the
/// private CoreSimulator frameworks.
protocol FrameCaptureBackend: AnyObject {
  func start(deviceUDID: String, onFrame: @escaping (CVPixelBuffer, Int, Int) -> Void) throws
  func stop()
}

extension FramebufferCapture: FrameCaptureBackend {}

extension ScreenshotPoller: FrameCaptureBackend {}
