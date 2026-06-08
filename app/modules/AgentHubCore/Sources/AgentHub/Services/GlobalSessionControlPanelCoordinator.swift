//
//  GlobalSessionControlPanelCoordinator.swift
//  AgentHub
//

import Foundation

public typealias GlobalSessionControlPanelPresenterFactory = @MainActor (
  _ provider: AgentHubProvider,
  _ defaults: UserDefaults
) -> any GlobalSessionControlPanelPresenting

// MARK: - GlobalSessionControlPanelPresenting

@MainActor
public protocol GlobalSessionControlPanelPresenting: AnyObject {
  var isVisible: Bool { get }

  func show()
  func hide()
}

public extension GlobalSessionControlPanelPresenting {
  func toggle() {
    isVisible ? hide() : show()
  }
}

// MARK: - NoOpGlobalSessionControlPanelPresenter

@MainActor
public final class NoOpGlobalSessionControlPanelPresenter: GlobalSessionControlPanelPresenting {
  public var isVisible: Bool { false }

  public init() {}

  public func show() {}
  public func hide() {}
}

// MARK: - GlobalSessionControlPanelCoordinator

@MainActor
@Observable
public final class GlobalSessionControlPanelCoordinator {
  public private(set) var registrationErrorMessage: String?

  private let registrar: any GlobalHotKeyRegistrarProtocol
  private let presenter: any GlobalSessionControlPanelPresenting
  private let defaults: UserDefaults
  private let hotKey: GlobalHotKey
  private var isStarted = false

  public var isPanelVisible: Bool {
    presenter.isVisible
  }

  public init(
    registrar: any GlobalHotKeyRegistrarProtocol,
    presenter: any GlobalSessionControlPanelPresenting,
    defaults: UserDefaults = .standard,
    hotKey: GlobalHotKey = .sessionControlPanelDefault
  ) {
    self.registrar = registrar
    self.presenter = presenter
    self.defaults = defaults
    self.hotKey = hotKey
  }

  public convenience init(
    provider: AgentHubProvider,
    defaults: UserDefaults = .standard
  ) {
    self.init(
      registrar: CarbonGlobalHotKeyRegistrar(),
      presenter: provider.makeGlobalSessionControlPanelPresenter(defaults: defaults),
      defaults: defaults
    )
  }

  public func start() {
    guard !isStarted else {
      syncHotKeyRegistration()
      return
    }
    isStarted = true
    registrar.onHotKeyPressed = { [weak self] in
      self?.togglePanel()
    }
    syncHotKeyRegistration()
  }

  public func stop() {
    registrar.unregister()
    registrar.onHotKeyPressed = nil
    presenter.hide()
    isStarted = false
    registrationErrorMessage = nil
  }

  public func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: AgentHubDefaults.globalSessionPanelEnabled)
    syncHotKeyRegistration()
  }

  public func syncHotKeyRegistration() {
    guard defaults.bool(forKey: AgentHubDefaults.globalSessionPanelEnabled) else {
      registrar.unregister()
      registrationErrorMessage = nil
      return
    }

    do {
      try registrar.register(hotKey: hotKey)
      registrationErrorMessage = nil
    } catch {
      registrar.unregister()
      registrationErrorMessage = error.localizedDescription
    }
  }

  public func togglePanel() {
    presenter.toggle()
  }
}
