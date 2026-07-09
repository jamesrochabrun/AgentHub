import CoreVideo
import Testing

@testable import SimulatorPreview

private final class FrameCaptureBackendSpy: FrameCaptureBackend {
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var lastOnFrame: ((CVPixelBuffer, Int, Int) -> Void)?

  func start(deviceUDID _: String, onFrame: @escaping (CVPixelBuffer, Int, Int) -> Void) throws {
    startCount += 1
    lastOnFrame = onFrame
  }

  func stop() {
    stopCount += 1
  }
}

@Suite("SimulatorStreamSession lifecycle")
struct SimulatorStreamSessionLifecycleTests {

  private func makeSession(
    backend kind: SimulatorStreamBackendKind = .coreSimulator,
    spy: FrameCaptureBackendSpy,
    isDeviceBooted: @escaping (String, String) -> Bool? = { _, _ in nil },
    watchdogInterval: TimeInterval = 0
  ) -> SimulatorStreamSession {
    let availability = SimulatorStreamAvailability(
      backend: kind,
      coreSimulatorFrameworkPath: nil,
      simulatorKitFrameworkPath: nil
    )
    let dependencies = SimulatorStreamSession.Dependencies(
      makeCapture: { _ in spy },
      makePoller: { _ in spy },
      makeHID: { _ in nil },
      isDeviceBooted: isDeviceBooted,
      watchdogInterval: watchdogInterval
    )
    return SimulatorStreamSession(
      udid: "TEST-UDID",
      availability: availability,
      developerDir: "/nonexistent/developer-dir",
      dependencies: dependencies
    )
  }

  private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    return pixelBuffer
  }

  @Test("start wires the capture backend exactly once")
  func startWiresBackendExactlyOnce() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)

    session.onFrame = { _ in }
    session.start()
    session.start()

    #expect(spy.startCount == 1)
    #expect(spy.stopCount == 0)
  }

  @Test("setting onFrame before start does not start capture")
  func settingOnFrameBeforeStartDoesNotStartCapture() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)

    session.onFrame = { _ in }

    #expect(spy.startCount == 0)
  }

  @Test("clearing onFrame pauses the capture backend")
  func clearingOnFramePausesCaptureBackend() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()

    session.onFrame = nil

    #expect(spy.startCount == 1)
    #expect(spy.stopCount == 1)
  }

  @Test("re-attaching onFrame resumes capture without a new session")
  func reattachingOnFrameResumesCapture() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()

    session.onFrame = nil
    session.onFrame = { _ in }

    #expect(spy.startCount == 2)
    #expect(spy.stopCount == 1)
    #expect(session.state != .stopped)
  }

  @Test("replacing an attached consumer does not restart capture")
  func replacingAttachedConsumerDoesNotRestartCapture() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()

    session.onFrame = { _ in }

    #expect(spy.startCount == 1)
    #expect(spy.stopCount == 0)
  }

  @Test("stop tears down and detach afterwards is a no-op")
  func stopTearsDownAndDetachIsNoOp() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()

    session.stop()
    #expect(spy.stopCount == 1)

    session.onFrame = nil
    session.onFrame = { _ in }

    #expect(spy.stopCount == 1)
    #expect(spy.startCount == 1)
    #expect(session.state == .stopped)
  }

  @Test("screenshot polling backend pauses and resumes identically")
  func screenshotPollingBackendPausesAndResumes() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(backend: .screenshotPolling, spy: spy)
    session.onFrame = { _ in }
    session.start()
    #expect(spy.startCount == 1)

    session.onFrame = nil
    #expect(spy.stopCount == 1)

    session.onFrame = { _ in }
    #expect(spy.startCount == 2)
  }

  @Test("watchdog: device shutdown fails the session and tears down capture")
  func watchdogFailsSessionOnShutdown() throws {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()
    let pixelBuffer = try #require(makePixelBuffer(width: 100, height: 200))
    spy.lastOnFrame?(pixelBuffer, 100, 200)

    session.applyWatchdogVerdict(deviceIsBooted: false)

    #expect(spy.stopCount == 1)
    guard case .failed = session.state else {
      Issue.record("expected .failed, got \(session.state)")
      return
    }
    // Repeated verdicts don't re-fail or touch the (already nil) backend.
    session.applyWatchdogVerdict(deviceIsBooted: false)
    #expect(spy.stopCount == 1)
  }

  @Test("watchdog: device coming back restarts capture while a consumer watches")
  func watchdogRestartsCaptureOnReboot() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()
    session.applyWatchdogVerdict(deviceIsBooted: false)
    #expect(spy.startCount == 1)

    session.applyWatchdogVerdict(deviceIsBooted: true)

    #expect(spy.startCount == 2)
    #expect(session.state == .starting)
  }

  @Test("watchdog: no self-heal restart while paused, and booted verdicts are no-ops mid-stream")
  func watchdogRespectsPauseAndSteadyState() {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()

    // Steady state: booted verdicts change nothing.
    session.applyWatchdogVerdict(deviceIsBooted: true)
    #expect(spy.startCount == 1)
    #expect(spy.stopCount == 0)

    // Death while paused still surfaces .failed, but no restart happens
    // until a consumer re-attaches.
    session.onFrame = nil
    session.applyWatchdogVerdict(deviceIsBooted: false)
    guard case .failed = session.state else {
      Issue.record("expected .failed, got \(session.state)")
      return
    }
    session.applyWatchdogVerdict(deviceIsBooted: true)
    #expect(spy.startCount == 1)
  }

  @Test("pause preserves the last streaming state")
  func pausePreservesLastStreamingState() throws {
    let spy = FrameCaptureBackendSpy()
    let session = makeSession(spy: spy)
    session.onFrame = { _ in }
    session.start()

    let pixelBuffer = try #require(makePixelBuffer(width: 100, height: 200))
    spy.lastOnFrame?(pixelBuffer, 100, 200)
    #expect(session.state == .streaming(width: 100, height: 200))

    session.onFrame = nil

    #expect(session.state == .streaming(width: 100, height: 200))
  }
}
