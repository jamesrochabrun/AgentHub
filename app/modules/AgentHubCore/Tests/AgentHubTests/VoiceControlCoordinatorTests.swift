import AgentHubVoice
import Foundation
import Testing
@testable import AgentHubCore

@MainActor
private final class MockVoiceHotKeyRegistrar: GlobalHotKeyRegistrarProtocol {
  var onHotKeyPressed: (@MainActor @Sendable () -> Void)?
  private(set) var registered: [GlobalHotKey] = []
  private(set) var unregisterCount = 0
  var error: Error?

  var isRegistered: Bool {
    !registered.isEmpty
  }

  func register(hotKey: GlobalHotKey) throws {
    if let error { throw error }
    registered.append(hotKey)
  }

  func unregister() {
    registered.removeAll()
    unregisterCount += 1
  }

  func fire() {
    onHotKeyPressed?()
  }
}

@MainActor
private final class MockVoiceHUDPresenter: VoiceHUDPresenting {
  private(set) var isVisible = false

  func show() {
    isVisible = true
  }

  func hide() {
    isVisible = false
  }
}

@MainActor
struct VoiceControlCoordinatorTests {
  @Test
  func defaultShortcutIsCommandOptionV() {
    #expect(GlobalHotKey.voiceHUDDefault.displayString == "⌘⌥V")
  }

  @Test
  func honorsPreferenceAndTogglesPresenter() {
    let defaults = makeDefaults()
    defaults.set(false, forKey: AgentHubDefaults.voiceEnabled)
    let registrar = MockVoiceHotKeyRegistrar()
    let presenter = MockVoiceHUDPresenter()
    let coordinator = VoiceControlCoordinator(
      registrar: registrar,
      presenter: presenter,
      defaults: defaults
    )

    coordinator.start()
    #expect(registrar.registered.isEmpty)

    coordinator.setEnabled(true)
    #expect(registrar.registered == [.voiceHUDDefault])

    registrar.fire()
    #expect(presenter.isVisible)
    registrar.fire()
    #expect(!presenter.isVisible)

    coordinator.setEnabled(false)
    #expect(registrar.registered.isEmpty)
  }

  @Test
  func surfacesRegistrationFailure() {
    let defaults = makeDefaults()
    defaults.set(true, forKey: AgentHubDefaults.voiceEnabled)
    let registrar = MockVoiceHotKeyRegistrar()
    registrar.error = GlobalHotKeyRegistrationError.registerFailed(status: -42)
    let coordinator = VoiceControlCoordinator(
      registrar: registrar,
      presenter: MockVoiceHUDPresenter(),
      defaults: defaults
    )

    coordinator.start()

    #expect(coordinator.registrationErrorMessage?.contains("-42") == true)
  }

  private func makeDefaults() -> UserDefaults {
    let suite = "VoiceControlCoordinatorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
