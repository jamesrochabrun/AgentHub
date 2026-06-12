import CoreVideo
import Foundation
import IOSurface
import ObjectiveC

// Adapted from EvanBacon/serve-sim `FrameCapture.swift` (Apache License 2.0).
// Trimmed to the in-process native path: we hand CVPixelBuffers straight to an
// AVSampleBufferDisplayLayer instead of H.264-encoding for an HTTP stream.

/// Headless simulator framebuffer capture via direct IOSurface access.
///
/// Registers SimulatorKit screen callbacks on the device's framebuffer display
/// IO port and wraps the live IOSurface in a CVPixelBuffer (zero-copy). A 5fps
/// idle floor re-emits the current frame so a late-attaching renderer paints
/// even while the simulator is idle.
///
/// The framebuffer descriptors are ROCKit remote proxies — every call on them
/// is an XPC round-trip into CoreSimulator. The hot path therefore never
/// touches a descriptor: the best descriptor's IOSurface is resolved once at
/// wiring time (`resolveActiveSurface`) and re-resolved only on the
/// surfaces-changed callback or via the staleness backstop; `captureFrame`
/// dedupes on `IOSurfaceGetSeed` (cheap, in-process) before any other work.
final class FramebufferCapture {
  private let developerDir: String
  private var onFrame: ((CVPixelBuffer, Int, Int) -> Void)?

  private var frameCount: UInt64 = 0
  private(set) var capturedWidth: Int = 0
  private(set) var capturedHeight: Int = 0

  private let captureQueue = DispatchQueue(label: "com.agenthub.simpreview.capture", qos: .userInteractive)
  private var idleTimer: DispatchSourceTimer?
  private var lastCaptureTimeMs: UInt64 = 0
  private var rewireTickCount: Int = 0
  private static let idleIntervalMs: UInt64 = 200

  /// The live framebuffer surface, resolved from the best descriptor at wiring
  /// time. Retaining it is what makes the per-frame seed check XPC-free.
  private var activeSurface: IOSurface?
  private var lastSeed: UInt32?
  private var lastSeedChangeTimeMs: UInt64 = 0
  private var lastFrameCallbackTimeMs: UInt64 = 0
  private var lastBackstopRewireTimeMs: UInt64 = 0
  /// Frames arriving while the cached surface's seed stays frozen this long
  /// means the surface was reallocated behind our back — rewire.
  private static let staleSurfaceThresholdMs: UInt64 = 3_000

  private var descriptors: [NSObject] = []
  private var callbackUUIDs: [ObjectIdentifier: NSUUID] = [:]
  private var ioClient: NSObject?

  init(developerDir: String) {
    self.developerDir = developerDir
  }

  func start(deviceUDID: String, onFrame: @escaping (CVPixelBuffer, Int, Int) -> Void) throws {
    self.onFrame = onFrame

    guard CoreSimulatorBridge.loadFrameworks(developerDir: developerDir) else {
      throw SimulatorStreamError.frameworkUnavailable(detail: "CoreSimulator.framework did not load")
    }

    guard let device = CoreSimulatorBridge.findSimDevice(udid: deviceUDID, developerDir: developerDir) else {
      throw SimulatorStreamError.deviceNotFound(udid: deviceUDID)
    }
    let state = CoreSimulatorBridge.stateString(of: device)
    guard state == "Booted" else {
      throw SimulatorStreamError.deviceNotBooted(udid: deviceUDID, state: state)
    }

    guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else {
      throw SimulatorStreamError.captureSetupFailed(detail: "device IO unavailable")
    }
    self.ioClient = io

    // All capture state is owned by captureQueue (frame callbacks land there).
    try captureQueue.sync {
      try wireUpFramebuffer()
    }
    startIdleTimer()
  }

  func stop() {
    idleTimer?.cancel()
    idleTimer = nil

    captureQueue.sync {
      let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
      for desc in descriptors {
        if let uuid = callbackUUIDs[ObjectIdentifier(desc)], desc.responds(to: unregSel) {
          desc.perform(unregSel, with: uuid)
        }
      }
      callbackUUIDs.removeAll()
      descriptors.removeAll()
      activeSurface = nil
      lastSeed = nil
      lastSeedChangeTimeMs = 0
      lastFrameCallbackTimeMs = 0
      lastBackstopRewireTimeMs = 0
    }
    ioClient = nil
    onFrame = nil
  }

  // MARK: - Framebuffer wiring

  private func wireUpFramebuffer() throws {
    guard let io = ioClient else {
      throw SimulatorStreamError.captureSetupFailed(detail: "no IO client")
    }
    io.perform(NSSelectorFromString("updateIOPorts"))

    let candidates = try findFramebufferDescriptors(io: io)

    let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
    for oldDesc in descriptors {
      if let uuid = callbackUUIDs[ObjectIdentifier(oldDesc)], oldDesc.responds(to: unregSel) {
        oldDesc.perform(unregSel, with: uuid)
      }
    }
    callbackUUIDs.removeAll()
    descriptors = candidates

    for desc in candidates {
      try registerFrameCallbacks(desc: desc)
    }

    resolveActiveSurface()
    captureFrame()
  }

  /// Resolves the best descriptor's IOSurface and caches it for the hot path.
  /// Resetting `lastSeed` forces the next `captureFrame` to emit even if the
  /// new surface's seed counter happens to equal the old one.
  private func resolveActiveSurface() {
    guard let best = pickBestDescriptor(),
      let surfObj = best.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue()
    else {
      activeSurface = nil
      lastSeed = nil
      return
    }
    let surface = unsafeBitCast(surfObj, to: IOSurface.self)
    activeSurface = surface
    lastSeed = nil
    capturedWidth = IOSurfaceGetWidth(surface)
    capturedHeight = IOSurfaceGetHeight(surface)
  }

  private func findFramebufferDescriptors(io: NSObject) throws -> [NSObject] {
    guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
      throw SimulatorStreamError.captureSetupFailed(detail: "no deviceIOPorts")
    }
    let pidSel = NSSelectorFromString("portIdentifier")
    let descSel = NSSelectorFromString("descriptor")
    let surfSel = NSSelectorFromString("framebufferSurface")

    var candidates: [NSObject] = []
    for port in ports {
      guard port.responds(to: pidSel),
        let pid = port.perform(pidSel)?.takeUnretainedValue(),
        "\(pid)" == "com.apple.framebuffer.display",
        port.responds(to: descSel),
        let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
        desc.responds(to: surfSel)
      else { continue }
      candidates.append(desc)
    }
    if candidates.isEmpty {
      throw SimulatorStreamError.captureSetupFailed(detail: "no framebuffer display descriptor")
    }
    return candidates
  }

  private func pickBestDescriptor() -> NSObject? {
    let surfSel = NSSelectorFromString("framebufferSurface")
    var best: NSObject?
    var bestArea = 0
    for desc in descriptors {
      guard let surfObj = desc.perform(surfSel)?.takeUnretainedValue() else { continue }
      let surf = unsafeBitCast(surfObj, to: IOSurface.self)
      let area = IOSurfaceGetWidth(surf) * IOSurfaceGetHeight(surf)
      if area > bestArea {
        best = desc
        bestArea = area
      }
    }
    return best
  }

  private func registerFrameCallbacks(desc: NSObject) throws {
    let regSel = NSSelectorFromString(
      "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
    guard desc.responds(to: regSel) else {
      throw SimulatorStreamError.captureSetupFailed(detail: "registerScreenCallbacks unsupported")
    }
    guard let msgSendPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
      throw SimulatorStreamError.captureSetupFailed(detail: "objc_msgSend missing")
    }
    typealias MsgSendFunc = @convention(c) (
      AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject
    ) -> Void
    let msgSend = unsafeBitCast(msgSendPtr, to: MsgSendFunc.self)

    let uuid = NSUUID()
    callbackUUIDs[ObjectIdentifier(desc)] = uuid

    let frameCallback: @convention(block) () -> Void = { [weak self] in
      self?.captureQueue.async {
        guard let self else { return }
        self.lastFrameCallbackTimeMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        self.captureFrame()
      }
    }
    let surfacesCallback: @convention(block) () -> Void = { [weak self] in
      self?.captureQueue.async {
        guard let self else { return }
        // The backing surface may have been reallocated — re-resolve before
        // capturing or the seed dedupe would freeze on the dead surface.
        self.resolveActiveSurface()
        self.captureFrame()
      }
    }
    let propsCallback: @convention(block) () -> Void = {}

    msgSend(
      desc, regSel,
      uuid, captureQueue as AnyObject,
      frameCallback as AnyObject, surfacesCallback as AnyObject, propsCallback as AnyObject)
  }

  private func startIdleTimer() {
    let timer = DispatchSource.makeTimerSource(queue: captureQueue)
    timer.schedule(
      deadline: .now().advanced(by: .milliseconds(Int(Self.idleIntervalMs))),
      repeating: .milliseconds(Int(Self.idleIntervalMs)))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
      if (nowMs - self.lastCaptureTimeMs) >= Self.idleIntervalMs {
        self.captureFrame()
      }
      if self.frameCount == 0 {
        self.rewireTickCount += 1
        if self.rewireTickCount % 5 == 0 {
          try? self.wireUpFramebuffer()
        }
      }
      // Staleness backstop: frame callbacks are arriving but the cached
      // surface's seed is frozen — a surfaces-changed event was missed
      // (rotation, scale change) and we're watching a dead surface. Rewire,
      // rate-limited so contentless callbacks can't trigger an XPC storm.
      let framesArriving = self.lastFrameCallbackTimeMs > 0
        && (nowMs &- self.lastFrameCallbackTimeMs) < 1_000
      let seedStale = (nowMs &- self.lastSeedChangeTimeMs) >= Self.staleSurfaceThresholdMs
      let backstopCooledDown = (nowMs &- self.lastBackstopRewireTimeMs) >= Self.staleSurfaceThresholdMs
      if self.frameCount > 0, framesArriving, seedStale, backstopCooledDown {
        self.lastBackstopRewireTimeMs = nowMs
        try? self.wireUpFramebuffer()
      }
    }
    timer.resume()
    self.idleTimer = timer
  }

  private func captureFrame() {
    guard let surface = activeSurface else { return }

    let seed = IOSurfaceGetSeed(surface)
    let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
    let sinceLastMs = nowMs &- lastCaptureTimeMs
    let seedChanged = lastSeed != seed
    let idleRefreshDue = frameCount > 0 && sinceLastMs >= Self.idleIntervalMs
    if frameCount > 0, !seedChanged, !idleRefreshDue { return }
    if seedChanged {
      lastSeedChangeTimeMs = nowMs
    }
    lastSeed = seed

    let w = IOSurfaceGetWidth(surface)
    let h = IOSurfaceGetHeight(surface)
    guard w > 0, h > 0 else { return }
    capturedWidth = w
    capturedHeight = h

    var pixelBuffer: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault, surface,
      [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
      &pixelBuffer)
    guard status == kCVReturnSuccess, let pb = pixelBuffer?.takeRetainedValue() else { return }

    lastCaptureTimeMs = nowMs
    frameCount += 1
    onFrame?(pb, w, h)
  }
}
