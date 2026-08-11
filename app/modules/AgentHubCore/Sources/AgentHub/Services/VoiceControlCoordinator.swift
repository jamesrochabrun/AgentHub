import AgentHubVoice
import Foundation

public typealias VoiceHUDPresenterFactory = @MainActor (
  _ provider: AgentHubProvider,
  _ defaults: UserDefaults
) -> any VoiceHUDPresenting

@MainActor
@Observable
public final class VoiceControlCoordinator {
  public private(set) var registrationErrorMessage: String?

  private let registrar: any GlobalHotKeyRegistrarProtocol
  private let presenter: any VoiceHUDPresenting
  private let defaults: UserDefaults
  private let hotKey: GlobalHotKey
  private var isStarted = false

  public var isHUDVisible: Bool {
    presenter.isVisible
  }

  public init(
    registrar: any GlobalHotKeyRegistrarProtocol,
    presenter: any VoiceHUDPresenting,
    defaults: UserDefaults = .standard,
    hotKey: GlobalHotKey = .voiceHUDDefault
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
      presenter: provider.makeVoiceHUDPresenter(defaults: defaults),
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
      self?.toggleHUD()
    }
    registrar.onHotKeyReleased = nil
    syncHotKeyRegistration()
  }

  public func stop() {
    registrar.unregister()
    registrar.onHotKeyPressed = nil
    registrar.onHotKeyReleased = nil
    presenter.hide()
    isStarted = false
    registrationErrorMessage = nil
  }

  public func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: AgentHubDefaults.voiceEnabled)
    syncHotKeyRegistration()
  }

  public func syncHotKeyRegistration() {
    guard defaults.bool(forKey: AgentHubDefaults.voiceEnabled) else {
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

  public func toggleHUD() {
    presenter.toggle()
  }
}
