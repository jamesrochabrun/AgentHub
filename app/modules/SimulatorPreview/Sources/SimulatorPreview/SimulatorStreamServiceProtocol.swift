import Foundation

/// A live stream of one simulator's display, plus optional input injection.
///
/// Frame and state callbacks fire on an internal capture queue — hop to the
/// main actor before touching UI state. AVSampleBufferDisplayLayer enqueueing
/// is thread-safe, so the render view consumes frames directly.
public protocol SimulatorStreamSessionProtocol: AnyObject {
  var udid: String { get }
  var backendKind: SimulatorStreamBackendKind { get }
  /// Whether touch/keyboard injection is available (CoreSimulator backend only).
  var supportsInteraction: Bool { get }
  /// Current lifecycle state. Lets late observers (e.g. an annotation overlay
  /// attached after streaming began) learn the frame dimensions without
  /// waiting for the next `onStateChange`.
  var state: SimulatorStreamSessionState { get }

  var onFrame: ((SimulatorStreamFrame) -> Void)? { get set }
  var onStateChange: ((SimulatorStreamSessionState) -> Void)? { get set }

  func start()
  func stop()

  /// Inject a touch at normalized display coordinates (0...1, top-left origin).
  func sendTouch(phase: SimulatorTouchPhase, normalizedX: Double, normalizedY: Double)
  /// Inject a USB HID keyboard event (usage page 0x07).
  func sendKey(direction: SimulatorKeyDirection, hidUsage: UInt32)
  func sendButton(_ button: SimulatorHardwareButton)
}

/// Factory for per-device stream sessions.
///
/// All capture stays inside the AgentHub process: no sockets, no helper
/// servers, no TCC permissions (Screen Recording/Accessibility are never
/// requested). Only the simulator's own framebuffer is ever read — never the
/// user's screen.
@MainActor
public protocol SimulatorStreamServiceProtocol: AnyObject {
  var availability: SimulatorStreamAvailability { get }
  /// Returns the active session for the device, creating one if needed.
  func session(forDeviceUDID udid: String) -> any SimulatorStreamSessionProtocol
  /// Stops and discards the session for the device, if any.
  func discardSession(forDeviceUDID udid: String)
  /// Stops all active sessions.
  func stopAll()
}
