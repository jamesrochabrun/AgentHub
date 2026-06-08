//
//  GlobalHotKeyRegistrar.swift
//  AgentHub
//

import Foundation

#if canImport(Carbon)
import Carbon
#endif

// MARK: - GlobalHotKey

public struct GlobalHotKey: Equatable, Sendable {
  public let keyCode: UInt32
  public let modifiers: UInt32
  public let displayString: String

  public init(keyCode: UInt32, modifiers: UInt32, displayString: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.displayString = displayString
  }

  public static var sessionControlPanelDefault: GlobalHotKey {
    #if canImport(Carbon)
    GlobalHotKey(
      keyCode: UInt32(kVK_ANSI_B),
      modifiers: UInt32(cmdKey | optionKey),
      displayString: "⌘⌥B"
    )
    #else
    GlobalHotKey(keyCode: 0, modifiers: 0, displayString: "⌘⌥B")
    #endif
  }
}

// MARK: - GlobalHotKeyRegistrationError

public enum GlobalHotKeyRegistrationError: Error, Equatable, LocalizedError {
  case carbonUnavailable
  case installHandlerFailed(status: Int32)
  case registerFailed(status: Int32)

  public var errorDescription: String? {
    switch self {
    case .carbonUnavailable:
      return "Global hotkeys are unavailable on this platform."
    case .installHandlerFailed(let status):
      return "Could not install the global hotkey handler (status \(status))."
    case .registerFailed(let status):
      return "Could not register the global hotkey (status \(status))."
    }
  }
}

// MARK: - GlobalHotKeyRegistrarProtocol

@MainActor
public protocol GlobalHotKeyRegistrarProtocol: AnyObject {
  var onHotKeyPressed: (@MainActor @Sendable () -> Void)? { get set }
  var isRegistered: Bool { get }

  func register(hotKey: GlobalHotKey) throws
  func unregister()
}

// MARK: - CarbonGlobalHotKeyRegistrar

@MainActor
public final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistrarProtocol {
  public var onHotKeyPressed: (@MainActor @Sendable () -> Void)?

  public var isRegistered: Bool {
    #if canImport(Carbon)
    hotKeyRef != nil
    #else
    false
    #endif
  }

  #if canImport(Carbon)
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private let hotKeyID = EventHotKeyID(
    signature: CarbonGlobalHotKeyRegistrar.fourCharCode("AHGP"),
    id: 1
  )
  #endif

  public init() {}

  deinit {
    #if canImport(Carbon)
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
    #endif
  }

  public func register(hotKey: GlobalHotKey) throws {
    #if canImport(Carbon)
    unregister()
    try installHandlerIfNeeded()

    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      hotKey.keyCode,
      hotKey.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &ref
    )
    guard status == noErr, let ref else {
      throw GlobalHotKeyRegistrationError.registerFailed(status: Int32(status))
    }
    hotKeyRef = ref
    #else
    throw GlobalHotKeyRegistrationError.carbonUnavailable
    #endif
  }

  public func unregister() {
    #if canImport(Carbon)
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    #endif
  }

  #if canImport(Carbon)
  private func installHandlerIfNeeded() throws {
    guard eventHandlerRef == nil else { return }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    var handlerRef: EventHandlerRef?
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let registrar = Unmanaged<CarbonGlobalHotKeyRegistrar>
          .fromOpaque(userData)
          .takeUnretainedValue()
        Task { @MainActor in
          registrar.onHotKeyPressed?()
        }
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &handlerRef
    )

    guard status == noErr, let handlerRef else {
      throw GlobalHotKeyRegistrationError.installHandlerFailed(status: Int32(status))
    }
    eventHandlerRef = handlerRef
  }

  private static func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { result, character in
      (result << 8) + OSType(character)
    }
  }
  #endif
}
