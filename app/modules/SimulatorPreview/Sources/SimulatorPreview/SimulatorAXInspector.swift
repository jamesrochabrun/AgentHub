import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

// Accessibility-tree inspection of a booted simulator, adapted from the
// approach in facebook/idb (MIT) — FBSimulatorAccessibilityCommands and
// FBAXTranslationDispatcher. The host-side `AccessibilityPlatformTranslation`
// private framework translates the simulated app's accessibility hierarchy
// into `AXPMacPlatformElement`s (NSAccessibilityElement subclasses we can read
// with public NSAccessibility API); each lazy attribute read is answered over
// CoreSimulator's `sendAccessibilityRequestAsync` XPC. All framework access is
// reflective and guarded so a missing/renamed symbol degrades to `nil`.

/// One element of the simulated app's accessibility tree.
///
/// `frame` is in device points with a top-left origin (the same orientation as
/// the framebuffer). The root element is the frontmost application, whose
/// frame is the device screen bounds — normalize child frames against it.
public struct SimulatorAXElement: Sendable, Equatable {
  /// Role with the "AX" prefix stripped, e.g. "Button", "StaticText".
  public let role: String?
  public let label: String?
  public let identifier: String?
  public let value: String?
  public let frame: CGRect
  public let children: [SimulatorAXElement]

  public init(
    role: String?, label: String?, identifier: String?, value: String?,
    frame: CGRect, children: [SimulatorAXElement]
  ) {
    self.role = role
    self.label = label
    self.identifier = identifier
    self.value = value
    self.frame = frame
    self.children = children
  }

  /// Depth-first flatten of this subtree (self first).
  public func flattened() -> [SimulatorAXElement] {
    [self] + children.flatMap { $0.flattened() }
  }

  /// The deepest descendant whose frame contains `point` (device points),
  /// preferring the smallest frame on ties. Returns nil when the point is
  /// outside this element.
  public func deepestElement(containing point: CGPoint) -> SimulatorAXElement? {
    guard frame.contains(point) else { return nil }
    var best = self
    var bestArea = frame.width * frame.height
    for child in children {
      guard let hit = child.deepestElement(containing: point) else { continue }
      let area = hit.frame.width * hit.frame.height
      if area > 0, area <= bestArea || bestArea == 0 {
        best = hit
        bestArea = area
      }
    }
    return best
  }

  /// A short human-readable summary, e.g. `Button "Like"`.
  public var summary: String {
    var parts: [String] = [role ?? "Element"]
    if let label, !label.isEmpty {
      parts.append("\"\(label)\"")
    } else if let identifier, !identifier.isEmpty {
      parts.append("`\(identifier)`")
    }
    return parts.joined(separator: " ")
  }
}

public enum SimulatorAXError: LocalizedError {
  case frameworkUnavailable
  case translatorUnavailable
  case deviceNotFound(udid: String)
  case accessibilityAPIUnavailable
  case noTranslationObject
  case elementConversionFailed

  public var errorDescription: String? {
    switch self {
    case .frameworkUnavailable:
      return "AccessibilityPlatformTranslation framework could not be loaded"
    case .translatorUnavailable:
      return "AXPTranslator is unavailable"
    case .deviceNotFound(let udid):
      return "Simulator \(udid) not found"
    case .accessibilityAPIUnavailable:
      return "CoreSimulator accessibility API is unavailable on this machine"
    case .noTranslationObject:
      return "No accessibility translation object was returned"
    case .elementConversionFailed:
      return "Failed to convert the accessibility translation to a platform element"
    }
  }
}

/// Fetches the frontmost app's accessibility tree from a booted simulator.
///
/// Thread-safe; all translator work runs on a private serial queue because the
/// translator's delegate callbacks block synchronously on XPC round-trips.
public final class SimulatorAXInspector: @unchecked Sendable {
  public static let shared = SimulatorAXInspector()

  private let workQueue = DispatchQueue(label: "com.agenthub.simpreview.ax", qos: .userInitiated)
  private let xpcCallbackQueue = DispatchQueue(label: "com.agenthub.simpreview.ax.xpc", qos: .userInitiated)
  private let delegate = AXTokenDelegate()

  private var didSetup = false
  private var translator: NSObject?

  // Bounds on tree traversal so a pathological hierarchy can't wedge the fetch.
  private let maxDepth = 50
  private let maxElements = 2000

  /// Whether the private framework + CoreSimulator AX API look usable.
  /// Performs the dlopen/setup on first call (cheap afterwards).
  public func isAvailable(developerDir: String) -> Bool {
    workQueue.sync { setupIfNeeded(developerDir: developerDir) }
  }

  /// Fetches the accessibility tree of the frontmost application on the
  /// device. Frames are in device points, top-left origin.
  public func fetchFrontmostTree(udid: String, developerDir: String) async throws -> SimulatorAXElement {
    try await withCheckedThrowingContinuation { continuation in
      workQueue.async { [self] in
        do {
          continuation.resume(returning: try fetchSync(udid: udid, developerDir: developerDir))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - Setup

  private func setupIfNeeded(developerDir: String) -> Bool {
    if didSetup { return translator != nil }
    didSetup = true

    CoreSimulatorBridge.loadFrameworks(developerDir: developerDir)
    let frameworkPath =
      "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
    guard dlopen(frameworkPath, RTLD_NOW) != nil else { return false }

    guard let translatorClass = NSClassFromString("AXPTranslator") as? NSObject.Type,
      translatorClass.responds(to: NSSelectorFromString("sharedInstance")),
      let shared = translatorClass.perform(NSSelectorFromString("sharedInstance"))?
        .takeUnretainedValue() as? NSObject
    else { return false }

    // Conform our delegate to the framework's protocol objects so any
    // conformsToProtocol: checks inside the translator pass.
    if let proto = objc_getProtocol("AXPTranslationTokenDelegateHelper") {
      class_addProtocol(AXTokenDelegate.self, proto)
    }
    if let proto = objc_getProtocol("AXPTranslationDelegateHelper") {
      class_addProtocol(AXTokenDelegate.self, proto)
    }
    delegate.xpcCallbackQueue = xpcCallbackQueue
    shared.setValue(delegate, forKey: "bridgeTokenDelegate")
    // Older translator paths consult the non-token delegate; the tokenized one
    // is only used when supportsDelegateTokens is set.
    shared.setValue(delegate, forKey: "bridgeDelegate")
    if shared.responds(to: NSSelectorFromString("setSupportsDelegateTokens:")) {
      shared.setValue(true, forKey: "supportsDelegateTokens")
    }
    translator = shared
    return true
  }

  // MARK: - Fetch

  private func fetchSync(udid: String, developerDir: String) throws -> SimulatorAXElement {
    guard setupIfNeeded(developerDir: developerDir), let translator else {
      throw SimulatorAXError.frameworkUnavailable
    }
    guard let device = CoreSimulatorBridge.findSimDevice(udid: udid, developerDir: developerDir) else {
      throw SimulatorAXError.deviceNotFound(udid: udid)
    }
    let sendSelector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
    guard device.responds(to: sendSelector) else {
      throw SimulatorAXError.accessibilityAPIUnavailable
    }

    let token = UUID().uuidString
    delegate.register(token: token, device: device)
    defer { delegate.unregister(token: token) }

    // translation = [translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token]
    let frontmostSelector = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
    guard let method = translator.method(for: frontmostSelector) else {
      throw SimulatorAXError.translatorUnavailable
    }
    typealias FrontmostFn = @convention(c) (NSObject, Selector, UInt32, NSString) -> Unmanaged<AnyObject>?
    let frontmost = unsafeBitCast(method, to: FrontmostFn.self)
    guard let translation = frontmost(translator, frontmostSelector, 0, token as NSString)?
      .takeUnretainedValue() as? NSObject
    else {
      throw SimulatorAXError.noTranslationObject
    }
    translation.setValue(token, forKey: "bridgeDelegateToken")

    // element = [translator macPlatformElementFromTranslation:translation]
    let convertSelector = NSSelectorFromString("macPlatformElementFromTranslation:")
    guard translator.responds(to: convertSelector),
      let element = translator.perform(convertSelector, with: translation)?
        .takeUnretainedValue() as? NSObject
    else {
      throw SimulatorAXError.elementConversionFailed
    }

    var count = 0
    return serialize(element, token: token, depth: 0, count: &count)
  }

  // MARK: - Traversal

  private func serialize(_ element: NSObject, token: String, depth: Int, count: inout Int) -> SimulatorAXElement {
    // Every element must carry the token so attribute reads route to our callback.
    if element.responds(to: NSSelectorFromString("translation")),
      let translation = element.value(forKey: "translation") as? NSObject {
      translation.setValue(token, forKey: "bridgeDelegateToken")
    }
    count += 1

    let frame = (safeValue(element, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    var role = safeValue(element, "accessibilityRole") as? String
    if let raw = role, raw.hasPrefix("AX") {
      role = String(raw.dropFirst(2))
    }
    let label = safeValue(element, "accessibilityLabel") as? String
    let identifier = safeValue(element, "accessibilityIdentifier") as? String
    let value = stringified(safeValue(element, "accessibilityValue"))

    var children: [SimulatorAXElement] = []
    if depth < maxDepth, count < maxElements,
      let rawChildren = safeValue(element, "accessibilityChildren") as? [NSObject] {
      for child in rawChildren {
        guard count < maxElements else { break }
        children.append(serialize(child, token: token, depth: depth + 1, count: &count))
      }
    }

    return SimulatorAXElement(
      role: role, label: label, identifier: identifier, value: value,
      frame: frame, children: children)
  }

  private func safeValue(_ element: NSObject, _ key: String) -> Any? {
    guard element.responds(to: NSSelectorFromString(key)) else { return nil }
    return element.value(forKey: key)
  }

  private func stringified(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    let text = String(describing: value)
    guard !text.isEmpty else { return nil }
    return String(text.prefix(200))
  }
}

// MARK: - Token delegate

/// Installed as `AXPTranslator.bridgeTokenDelegate`. The translator hands it a
/// token per request; the returned block answers each translator request by
/// blocking on a CoreSimulator `sendAccessibilityRequestAsync` round-trip
/// (5s timeout per attribute read, mirroring idb).
private final class AXTokenDelegate: NSObject {
  var xpcCallbackQueue = DispatchQueue(label: "com.agenthub.simpreview.ax.xpc.default")

  private let lock = NSLock()
  private var tokenToDevice: [String: NSObject] = [:]
  private var currentDevice: NSObject?

  private static let requestTimeout: TimeInterval = 5.0
  static let debug = ProcessInfo.processInfo.environment["AGENTHUB_AX_DEBUG"] == "1"

  static func log(_ message: @autoclosure () -> String) {
    guard debug else { return }
    FileHandle.standardError.write(Data("[ax] \(message())\n".utf8))
  }

  func register(token: String, device: NSObject) {
    lock.lock()
    tokenToDevice[token] = device
    currentDevice = device
    lock.unlock()
  }

  func unregister(token: String) {
    lock.lock()
    tokenToDevice.removeValue(forKey: token)
    lock.unlock()
  }

  private func device(forToken token: String?) -> NSObject? {
    lock.lock()
    defer { lock.unlock() }
    if let token, let device = tokenToDevice[token] { return device }
    return currentDevice
  }

  private static func emptyResponse() -> AnyObject? {
    guard let responseClass = NSClassFromString("AXPTranslatorResponse") as? NSObject.Type,
      responseClass.responds(to: NSSelectorFromString("emptyResponse"))
    else { return nil }
    return responseClass.perform(NSSelectorFromString("emptyResponse"))?.takeUnretainedValue()
  }

  // Blocks are ObjC objects, so a `@convention(block)` closure returned as the
  // method's value matches the protocol's `AXPTranslationCallback` return.
  private func makeCallback(token: String?) -> @convention(block) (AnyObject?) -> AnyObject? {
    let device = device(forToken: token)
    let queue = xpcCallbackQueue
    return { axpRequest in
      Self.log("callback invoked (token: \(token ?? "none")), request: \(axpRequest.map { String(describing: $0) } ?? "nil")")
      guard let device, let axpRequest else { return Self.emptyResponse() }
      let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
      guard let method = device.method(for: selector) else { return Self.emptyResponse() }

      // The CoreSimulator API is asynchronous while the translator expects a
      // synchronous answer; bridge with a bounded DispatchGroup wait. This
      // always runs off the main queue (translator work stays on workQueue).
      let group = DispatchGroup()
      group.enter()
      let box = ResponseBox()
      let handler: @convention(block) (AnyObject?) -> Void = { response in
        box.response = response
        group.leave()
      }
      typealias SendFn = @convention(c) (NSObject, Selector, AnyObject, AnyObject, AnyObject) -> Void
      let send = unsafeBitCast(method, to: SendFn.self)
      send(device, selector, axpRequest, queue, handler as AnyObject)
      guard group.wait(timeout: .now() + Self.requestTimeout) == .success else {
        Self.log("XPC round-trip timed out")
        return Self.emptyResponse()
      }
      Self.log("response: \(box.response.map { String(describing: $0) } ?? "nil")")
      return box.response ?? Self.emptyResponse()
    }
  }

  // MARK: AXPTranslationTokenDelegateHelper

  // - (AXPTranslationCallback)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token
  @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
  func bridgeCallback(withToken token: String) -> Any {
    Self.log("bridgeCallbackWithToken: \(token)")
    return makeCallback(token: token)
  }

  // - (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:withToken:
  // Identity: keeps frames in the device's own coordinate space (top-left points).
  @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
  func convertPlatformFrame(toSystem rect: CGRect, withToken token: String) -> CGRect {
    rect
  }

  // - (id)accessibilityTranslationRootParentWithToken:
  @objc(accessibilityTranslationRootParentWithToken:)
  func rootParent(withToken token: String) -> Any? {
    nil
  }

  // MARK: AXPTranslationDelegateHelper (non-token variants)

  // - (AXPTranslationCallback)accessibilityTranslationDelegateBridgeCallback
  @objc(accessibilityTranslationDelegateBridgeCallback)
  func bridgeCallback() -> Any {
    Self.log("bridgeCallback (non-token)")
    return makeCallback(token: nil)
  }

  // - (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:withContext:postProcess:
  @objc(accessibilityTranslationConvertPlatformFrameToSystem:withContext:postProcess:)
  func convertPlatformFrame(toSystem rect: CGRect, withContext context: Any?, postProcess: Any?) -> CGRect {
    rect
  }

  // - (id)accessibilityTranslationRootParent
  @objc(accessibilityTranslationRootParent)
  func rootParent() -> Any? {
    nil
  }
}

/// Mutable holder so the synchronous bridge can capture the async response.
/// The DispatchGroup wait establishes the needed happens-before.
private final class ResponseBox: @unchecked Sendable {
  var response: AnyObject?
}
