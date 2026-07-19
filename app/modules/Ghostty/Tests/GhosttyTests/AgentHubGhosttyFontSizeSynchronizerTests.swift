import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite("AgentHub Ghostty font size synchronizer")
struct AgentHubGhosttyFontSizeSynchronizerTests {
  @Test("Applies the requested font size to every open controller")
  func appliesFontSizeToEveryController() {
    let first = MockFontSizeController()
    let second = MockFontSizeController()
    let synchronizer = AgentHubGhosttyFontSizeSynchronizer()

    synchronizer.sync(fontSize: 14, controllers: [first, second])

    #expect(first.actions == ["set_font_size:14.0"])
    #expect(second.actions == ["set_font_size:14.0"])
    #expect(synchronizer.fontSize == 14)
  }

  @Test("Skips unchanged controllers but updates newly opened controllers")
  func skipsUnchangedControllersAndUpdatesNewControllers() {
    let existing = MockFontSizeController()
    let added = MockFontSizeController()
    let synchronizer = AgentHubGhosttyFontSizeSynchronizer()

    synchronizer.sync(fontSize: 13, controllers: [existing])
    synchronizer.sync(fontSize: 13, controllers: [existing, added])

    #expect(existing.actions == ["set_font_size:13.0"])
    #expect(added.actions == ["set_font_size:13.0"])
  }

  @Test("Reapplies font size after a configuration overlay update")
  func reappliesFontSizeAfterConfigurationUpdate() {
    let controller = MockFontSizeController()
    let synchronizer = AgentHubGhosttyFontSizeSynchronizer()

    synchronizer.sync(fontSize: 15, controllers: [controller])
    synchronizer.sync(
      fontSize: 15,
      controllers: [controller],
      forceControllerIDs: [ObjectIdentifier(controller)]
    )

    #expect(controller.actions == [
      "set_font_size:15.0",
      "set_font_size:15.0",
    ])
  }

  @Test("Retries when Ghostty cannot apply the action yet")
  func retriesFailedAction() {
    let controller = MockFontSizeController(results: [false, true])
    let synchronizer = AgentHubGhosttyFontSizeSynchronizer()

    synchronizer.sync(fontSize: 16, controllers: [controller])
    synchronizer.sync(fontSize: 16, controllers: [controller])

    #expect(controller.actions == [
      "set_font_size:16.0",
      "set_font_size:16.0",
    ])
  }

  @Test("Clamps font size to the terminal minimum")
  func clampsFontSizeToMinimum() {
    let controller = MockFontSizeController()
    let synchronizer = AgentHubGhosttyFontSizeSynchronizer()

    synchronizer.sync(fontSize: 4, controllers: [controller])

    #expect(controller.actions == ["set_font_size:8.0"])
    #expect(synchronizer.fontSize == 8)
  }

  @Test("Retains the requested size before a native controller mounts")
  func retainsFontSizeWithoutControllers() {
    let synchronizer = AgentHubGhosttyFontSizeSynchronizer()

    synchronizer.sync(fontSize: 17, controllers: [])

    #expect(synchronizer.fontSize == 17)
  }
}

@MainActor
private final class MockFontSizeController: AgentHubGhosttyFontSizeControlling {
  private var results: [Bool]
  private(set) var actions: [String] = []

  init(results: [Bool] = [true]) {
    self.results = results
  }

  func performBindingAction(_ action: String) -> Bool {
    actions.append(action)
    return results.isEmpty ? true : results.removeFirst()
  }
}
