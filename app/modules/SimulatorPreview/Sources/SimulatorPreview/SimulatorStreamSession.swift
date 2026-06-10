import CoreVideo
import Foundation

/// One device's live capture session. Picks the CoreSimulator backend when the
/// private frameworks are present, otherwise falls back to screenshot polling.
final class SimulatorStreamSession: SimulatorStreamSessionProtocol {
  let udid: String
  let backendKind: SimulatorStreamBackendKind
  var supportsInteraction: Bool { backendKind == .coreSimulator && hid?.isReady == true }

  var onFrame: ((SimulatorStreamFrame) -> Void)?
  var onStateChange: ((SimulatorStreamSessionState) -> Void)?

  var state: SimulatorStreamSessionState {
    lock.lock()
    defer { lock.unlock() }
    return currentState
  }

  private let developerDir: String
  private let availability: SimulatorStreamAvailability
  private var capture: FramebufferCapture?
  private var poller: ScreenshotPoller?
  private var hid: HIDInjector?

  private var lastWidth = 0
  private var lastHeight = 0
  private var started = false
  private var currentState: SimulatorStreamSessionState = .idle
  private let lock = NSLock()

  init(udid: String, availability: SimulatorStreamAvailability, developerDir: String) {
    self.udid = udid
    self.availability = availability
    self.developerDir = developerDir
    self.backendKind = availability.backend
  }

  func start() {
    lock.lock()
    guard !started else { lock.unlock(); return }
    started = true
    lock.unlock()

    transition(to: .starting)
    switch backendKind {
    case .coreSimulator:
      startCoreSimulator()
    case .screenshotPolling:
      startScreenshotPolling()
    }
  }

  func stop() {
    lock.lock()
    let wasStarted = started
    started = false
    lock.unlock()
    guard wasStarted else { return }

    capture?.stop()
    capture = nil
    poller?.stop()
    poller = nil
    hid?.teardown()
    hid = nil
    transition(to: .stopped)
  }

  private func transition(to newState: SimulatorStreamSessionState) {
    lock.lock()
    currentState = newState
    lock.unlock()
    onStateChange?(newState)
  }

  // MARK: - Backends

  private func startCoreSimulator() {
    let capture = FramebufferCapture(developerDir: developerDir)
    self.capture = capture

    // HID is best-effort: capture can still run view-only if injection fails.
    let hid = HIDInjector(developerDir: developerDir)
    do {
      try hid.setup(deviceUDID: udid)
      self.hid = hid
    } catch {
      self.hid = nil
    }

    do {
      try capture.start(deviceUDID: udid) { [weak self] pb, w, h in
        self?.emit(pixelBuffer: pb, width: w, height: h)
      }
    } catch {
      self.capture = nil
      // Fall back to view-only polling if the private path failed at runtime.
      startScreenshotPolling()
    }
  }

  private func startScreenshotPolling() {
    let poller = ScreenshotPoller(udid: udid)
    self.poller = poller
    poller.start { [weak self] pb, w, h in
      self?.emit(pixelBuffer: pb, width: w, height: h)
    }
  }

  private func emit(pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
    if width != lastWidth || height != lastHeight {
      lastWidth = width
      lastHeight = height
      transition(to: .streaming(width: width, height: height))
    }
    onFrame?(SimulatorStreamFrame(pixelBuffer: pixelBuffer, width: width, height: height))
  }

  // MARK: - Input

  func sendTouch(phase: SimulatorTouchPhase, normalizedX: Double, normalizedY: Double) {
    let x = min(max(normalizedX, 0), 1)
    let y = min(max(normalizedY, 0), 1)
    hid?.sendTouch(type: phase, normalizedX: x, normalizedY: y)
  }

  func sendKey(direction: SimulatorKeyDirection, hidUsage: UInt32) {
    hid?.sendKey(direction: direction, usage: hidUsage)
  }

  func sendButton(_ button: SimulatorHardwareButton) {
    hid?.sendButton(button, deviceUDID: udid)
  }
}
