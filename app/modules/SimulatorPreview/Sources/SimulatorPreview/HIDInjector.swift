import Foundation
import ObjectiveC

// Adapted from EvanBacon/serve-sim `HIDInjector.swift` (Apache License 2.0).
// Trimmed to touch, keyboard, and core hardware buttons.

/// Injects touch, keyboard, and hardware-button HID events into a booted
/// simulator via SimulatorKit's Indigo HID functions and
/// `SimDeviceLegacyHIDClient`. Requires no TCC permissions: events go straight
/// to the simulator device, not through the window server.
final class HIDInjector {
  private var hidClient: NSObject?
  private var sendSel: Selector?
  private var simDevice: NSObject?
  private let developerDir: String

  // IndigoHIDMessageForMouseNSEvent(CGPoint*, CGPoint*, target, NSEventType, NSSize.w, NSSize.h, edge)
  private typealias IndigoMouseFunc = @convention(c) (
    UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32
  ) -> UnsafeMutableRawPointer?
  private var mouseFunc: IndigoMouseFunc?

  // IndigoHIDMessageForButton(eventSource, direction, target)
  private typealias IndigoButtonFunc = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
  private var buttonFunc: IndigoButtonFunc?

  // IndigoHIDMessageForKeyboardArbitrary(usage, direction)
  private typealias IndigoKeyboardFunc = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
  private var keyboardFunc: IndigoKeyboardFunc?

  private let buttonQueue = DispatchQueue(label: "com.agenthub.simpreview.hid-button")

  var isReady: Bool { hidClient != nil && mouseFunc != nil }
  var supportsKeyboard: Bool { hidClient != nil && keyboardFunc != nil }
  var supportsButtons: Bool { hidClient != nil && buttonFunc != nil }

  init(developerDir: String) {
    self.developerDir = developerDir
  }

  func setup(deviceUDID: String) throws {
    guard CoreSimulatorBridge.loadFrameworks(developerDir: developerDir) else {
      throw SimulatorStreamError.frameworkUnavailable(detail: "CoreSimulator.framework did not load")
    }
    guard let device = CoreSimulatorBridge.findSimDevice(udid: deviceUDID, developerDir: developerDir) else {
      throw SimulatorStreamError.deviceNotFound(udid: deviceUDID)
    }
    self.simDevice = device

    guard let funcPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForMouseNSEvent") else {
      throw SimulatorStreamError.captureSetupFailed(detail: "IndigoHIDMessageForMouseNSEvent missing")
    }
    self.mouseFunc = unsafeBitCast(funcPtr, to: IndigoMouseFunc.self)

    if let buttonPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForButton") {
      self.buttonFunc = unsafeBitCast(buttonPtr, to: IndigoButtonFunc.self)
    }
    if let keyboardPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForKeyboardArbitrary") {
      self.keyboardFunc = unsafeBitCast(keyboardPtr, to: IndigoKeyboardFunc.self)
    }

    guard let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
      throw SimulatorStreamError.captureSetupFailed(detail: "SimDeviceLegacyHIDClient missing")
    }
    let initSel = NSSelectorFromString("initWithDevice:error:")
    typealias HIDInitFunc = @convention(c) (
      AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    guard let initIMP = class_getMethodImplementation(hidClass, initSel) else {
      throw SimulatorStreamError.captureSetupFailed(detail: "HID client init unavailable")
    }
    let initFunc = unsafeBitCast(initIMP, to: HIDInitFunc.self)

    var error: NSError?
    let client = initFunc(hidClass.alloc(), initSel, device, &error)
    if let error { throw error }
    guard let clientObj = client as? NSObject else {
      throw SimulatorStreamError.captureSetupFailed(detail: "HID client creation failed")
    }
    self.hidClient = clientObj
    self.sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
  }

  func teardown() {
    hidClient = nil
    simDevice = nil
    mouseFunc = nil
    buttonFunc = nil
    keyboardFunc = nil
  }

  // MARK: - Edge constants

  static let edgeNone: UInt32 = 0
  static let edgeBottom: UInt32 = 3

  // MARK: - Touch

  func sendTouch(type: SimulatorTouchPhase, normalizedX: Double, normalizedY: Double, edge: UInt32 = 0) {
    guard let client = hidClient, let sendSel, let mouseFunc else { return }
    var point = CGPoint(x: normalizedX, y: normalizedY)
    let eventType: Int32
    switch type {
    case .began: eventType = 1  // NSEventTypeLeftMouseDown
    case .moved: eventType = 1  // continued touch uses Down, not Dragged
    case .ended: eventType = 2  // NSEventTypeLeftMouseUp
    }
    guard let rawMsg = mouseFunc(&point, nil, 0x32, eventType, 1.0, 1.0, edge) else { return }
    sendRawMessage(rawMsg, client: client, sendSel: sendSel)
  }

  // MARK: - Keyboard

  func sendKey(direction: SimulatorKeyDirection, usage: UInt32) {
    guard let client = hidClient, let sendSel, let keyboardFunc else { return }
    let dir: UInt32 = (direction == .down) ? 1 : 2
    guard let msg = keyboardFunc(usage, dir) else { return }
    sendRawMessage(msg, client: client, sendSel: sendSel)
  }

  // MARK: - Buttons

  private static let buttonSourceHome: Int32 = 0x0
  private static let buttonSourceLock: Int32 = 0x1
  private static let buttonDown: Int32 = 1
  private static let buttonUp: Int32 = 2
  private static let buttonTargetHardware: Int32 = 0x33

  private func sendHIDButton(eventSource: Int32, direction: Int32) {
    guard let client = hidClient, let sendSel, let buttonFunc else { return }
    guard let msg = buttonFunc(eventSource, direction, Self.buttonTargetHardware) else { return }
    sendRawMessage(msg, client: client, sendSel: sendSel)
  }

  func sendButton(_ button: SimulatorHardwareButton, deviceUDID: String) {
    switch button {
    case .home:
      if buttonFunc != nil {
        sendHIDButton(eventSource: Self.buttonSourceHome, direction: Self.buttonDown)
        sendHIDButton(eventSource: Self.buttonSourceHome, direction: Self.buttonUp)
      } else {
        launchSpringBoard(deviceUDID: deviceUDID)
      }
    case .swipeHome:
      buttonQueue.async { [self] in sendSwipeHome() }
    case .appSwitcher:
      guard buttonFunc != nil else { return }
      buttonQueue.async { [self] in
        sendHIDButton(eventSource: Self.buttonSourceHome, direction: Self.buttonDown)
        sendHIDButton(eventSource: Self.buttonSourceHome, direction: Self.buttonUp)
        Thread.sleep(forTimeInterval: 0.15)
        sendHIDButton(eventSource: Self.buttonSourceHome, direction: Self.buttonDown)
        sendHIDButton(eventSource: Self.buttonSourceHome, direction: Self.buttonUp)
      }
    case .lock:
      sendHIDButton(eventSource: Self.buttonSourceLock, direction: Self.buttonDown)
      sendHIDButton(eventSource: Self.buttonSourceLock, direction: Self.buttonUp)
    }
  }

  private func sendSwipeHome() {
    let xPos = 0.5, yStart = 0.95, yEnd = 0.35, steps = 10
    let stepDelay: TimeInterval = 0.016
    let edge = Self.edgeBottom
    sendTouch(type: .began, normalizedX: xPos, normalizedY: yStart, edge: edge)
    Thread.sleep(forTimeInterval: stepDelay)
    for i in 1...steps {
      let t = Double(i) / Double(steps)
      let y = yStart + (yEnd - yStart) * t
      sendTouch(type: .moved, normalizedX: xPos, normalizedY: y, edge: edge)
      Thread.sleep(forTimeInterval: stepDelay)
    }
    sendTouch(type: .ended, normalizedX: xPos, normalizedY: yEnd, edge: edge)
  }

  private func launchSpringBoard(deviceUDID: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "launch", deviceUDID, "com.apple.springboard"]
    try? process.run()
  }

  // MARK: - Send

  private func sendRawMessage(_ rawMsg: UnsafeMutableRawPointer, client: NSObject, sendSel: Selector) {
    typealias SendFunc = @convention(c) (
      AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
    ) -> Void
    guard let sendIMP = class_getMethodImplementation(object_getClass(client)!, sendSel) else {
      free(rawMsg)
      return
    }
    let sendFunc = unsafeBitCast(sendIMP, to: SendFunc.self)
    sendFunc(client, sendSel, rawMsg, ObjCBool(true), nil, nil)
  }
}
