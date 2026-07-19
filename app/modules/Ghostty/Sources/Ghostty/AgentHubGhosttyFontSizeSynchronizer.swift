import AppKit
import GhosttySwift

@MainActor
protocol AgentHubGhosttyFontSizeControlling: AnyObject {
  @discardableResult
  func performBindingAction(_ action: String) -> Bool
}

extension GhosttyTerminalController: AgentHubGhosttyFontSizeControlling {}

@MainActor
final class AgentHubGhosttyFontSizeSynchronizer {
  private(set) var fontSize: Float?
  private var appliedFontSizes: [ObjectIdentifier: Float] = [:]

  func sync(
    fontSize: CGFloat,
    controllers: [any AgentHubGhosttyFontSizeControlling],
    forceControllerIDs: Set<ObjectIdentifier> = []
  ) {
    let resolvedFontSize = Float(max(fontSize, 8))
    self.fontSize = resolvedFontSize

    let activeControllerIDs = Set(controllers.map(ObjectIdentifier.init))
    appliedFontSizes = appliedFontSizes.filter { activeControllerIDs.contains($0.key) }

    for controller in controllers {
      let controllerID = ObjectIdentifier(controller)
      guard forceControllerIDs.contains(controllerID)
        || appliedFontSizes[controllerID] != resolvedFontSize
      else { continue }

      if controller.performBindingAction("set_font_size:\(resolvedFontSize)") {
        appliedFontSizes[controllerID] = resolvedFontSize
      }
    }
  }
}
