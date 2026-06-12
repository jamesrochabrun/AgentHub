import CoreVideo
import Foundation

/// One device's live capture session. Picks the CoreSimulator backend when the
/// private frameworks are present, otherwise falls back to screenshot polling.
final class SimulatorStreamSession: SimulatorStreamSessionProtocol {

  /// Backend/HID factories, injectable so lifecycle tests run without the
  /// private CoreSimulator frameworks.
  struct Dependencies {
    var makeCapture: (_ developerDir: String) -> FrameCaptureBackend
    var makePoller: (_ udid: String) -> FrameCaptureBackend
    var makeHID: (_ developerDir: String) -> HIDInjector?

    static let live = Dependencies(
      makeCapture: { FramebufferCapture(developerDir: $0) },
      makePoller: { ScreenshotPoller(udid: $0) },
      makeHID: { HIDInjector(developerDir: $0) }
    )
  }

  let udid: String
  let backendKind: SimulatorStreamBackendKind
  var supportsInteraction: Bool { backendKind == .coreSimulator && hid?.isReady == true }

  /// Setting nil pauses capture — the framebuffer tap and the screenshot
  /// poller both burn CPU with nobody watching. Setting a consumer on a
  /// started session resumes it. HID and the last streaming state survive a
  /// pause so re-show paints and accepts input immediately.
  var onFrame: ((SimulatorStreamFrame) -> Void)? {
    didSet { onFrameConsumerChanged() }
  }
  var onStateChange: ((SimulatorStreamSessionState) -> Void)?

  var state: SimulatorStreamSessionState {
    lock.lock()
    defer { lock.unlock() }
    return currentState
  }

  private let developerDir: String
  private let availability: SimulatorStreamAvailability
  private let dependencies: Dependencies
  private var backend: FrameCaptureBackend?
  private var hid: HIDInjector?

  private var lastWidth = 0
  private var lastHeight = 0
  private var started = false
  private var currentState: SimulatorStreamSessionState = .idle
  private let lock = NSLock()

  init(
    udid: String,
    availability: SimulatorStreamAvailability,
    developerDir: String,
    dependencies: Dependencies = .live
  ) {
    self.udid = udid
    self.availability = availability
    self.developerDir = developerDir
    self.backendKind = availability.backend
    self.dependencies = dependencies
  }

  func start() {
    lock.lock()
    guard !started else { lock.unlock(); return }
    started = true
    lock.unlock()

    transition(to: .starting)
    startBackend()
  }

  func stop() {
    lock.lock()
    let wasStarted = started
    started = false
    lock.unlock()
    guard wasStarted else { return }

    backend?.stop()
    backend = nil
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

  // MARK: - Pause/resume

  private func onFrameConsumerChanged() {
    lock.lock()
    let isStarted = started
    let hasConsumer = onFrame != nil
    lock.unlock()
    guard isStarted else { return }

    if hasConsumer {
      resumeCaptureIfNeeded()
    } else {
      pauseCapture()
    }
  }

  private func pauseCapture() {
    backend?.stop()
    backend = nil
    // HID stays alive (instant input on re-show) and currentState keeps the
    // last .streaming dimensions so late observers can still read them.
  }

  private func resumeCaptureIfNeeded() {
    guard backend == nil else { return }
    startBackend()
  }

  // MARK: - Backends

  private func startBackend() {
    switch backendKind {
    case .coreSimulator:
      startCoreSimulator()
    case .screenshotPolling:
      startScreenshotPolling()
    }
  }

  private func startCoreSimulator() {
    setupHIDIfNeeded()

    let capture = dependencies.makeCapture(developerDir)
    backend = capture
    do {
      try capture.start(deviceUDID: udid) { [weak self] pb, w, h in
        self?.emit(pixelBuffer: pb, width: w, height: h)
      }
    } catch {
      backend = nil
      // Fall back to view-only polling if the private path failed at runtime.
      startScreenshotPolling()
    }
  }

  private func setupHIDIfNeeded() {
    guard hid == nil, let hid = dependencies.makeHID(developerDir) else { return }
    // HID is best-effort: capture can still run view-only if injection fails.
    do {
      try hid.setup(deviceUDID: udid)
      self.hid = hid
    } catch {
      self.hid = nil
    }
  }

  private func startScreenshotPolling() {
    let poller = dependencies.makePoller(udid)
    backend = poller
    do {
      try poller.start(deviceUDID: udid) { [weak self] pb, w, h in
        self?.emit(pixelBuffer: pb, width: w, height: h)
      }
    } catch {
      backend = nil
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
