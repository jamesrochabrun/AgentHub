import CoreVideo
import Foundation

/// A single captured simulator display frame.
///
/// For the CoreSimulator backend the pixel buffer wraps the simulator's live
/// framebuffer IOSurface (zero-copy). For the screenshot-polling fallback it is
/// a decoded PNG. Either way the buffer is BGRA and safe to hand to
/// AVSampleBufferDisplayLayer.
public struct SimulatorStreamFrame {
  public let pixelBuffer: CVPixelBuffer
  public let width: Int
  public let height: Int

  public init(pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
    self.pixelBuffer = pixelBuffer
    self.width = width
    self.height = height
  }
}

/// Which capture backend a stream session is using.
public enum SimulatorStreamBackendKind: String, Sendable, Equatable {
  /// Direct framebuffer access through CoreSimulator/SimulatorKit.
  /// 60fps, zero-copy, and supports touch/keyboard injection.
  case coreSimulator
  /// Public `xcrun simctl io screenshot` polling. Low frame rate, view-only.
  case screenshotPolling
}

/// Lifecycle state of a stream session.
public enum SimulatorStreamSessionState: Equatable, Sendable {
  case idle
  case starting
  case streaming(width: Int, height: Int)
  case stopped
  case failed(message: String)
}

/// Touch phases mirroring a mouse drag gesture.
public enum SimulatorTouchPhase: Sendable {
  case began
  case moved
  case ended
}

/// Hardware buttons that can be injected into the simulated device.
public enum SimulatorHardwareButton: Sendable {
  case home
  /// Swipe-up-from-bottom-edge gesture (go home on Face ID devices).
  case swipeHome
  case appSwitcher
  case lock
}

/// Key event direction for USB HID keyboard injection.
public enum SimulatorKeyDirection: Sendable {
  case down
  case up
}

public enum SimulatorStreamError: LocalizedError {
  case deviceNotFound(udid: String)
  case deviceNotBooted(udid: String, state: String)
  case frameworkUnavailable(detail: String)
  case captureSetupFailed(detail: String)

  public var errorDescription: String? {
    switch self {
    case .deviceNotFound(let udid):
      return "Simulator \(udid) not found"
    case .deviceNotBooted(let udid, let state):
      return "Simulator \(udid) is not booted (state: \(state))"
    case .frameworkUnavailable(let detail):
      return "CoreSimulator frameworks unavailable: \(detail)"
    case .captureSetupFailed(let detail):
      return "Failed to start simulator capture: \(detail)"
    }
  }
}
