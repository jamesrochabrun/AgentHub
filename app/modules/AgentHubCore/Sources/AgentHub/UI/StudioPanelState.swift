import AgentHubCLIKit
import Foundation
import Observation

/// Everything the Studio panel decides, kept out of the view so it can be tested.
@MainActor
@Observable
public final class StudioPanelState {
  /// Explicit user selection. `nil` means "follow the agent" — the most recently
  /// updated artifact.
  public var selectedArtifactId: String?
  public private(set) var manualReloadCount = 0
  public var failureMessage: String?

  public init() {}

  /// The artifact on screen: the explicit selection when it still exists,
  /// otherwise the most recently updated one — the thing the agent just filed.
  public func selectedArtifact(in artifacts: [StudioArtifact]) -> StudioArtifact? {
    if let selectedArtifactId, let match = artifacts.first(where: { $0.id == selectedArtifactId }) {
      return match
    }
    return Self.mostRecentlyUpdated(in: artifacts)
  }

  /// Identity of what should be loaded: switching artifacts, the agent
  /// re-filing the open one, and Reload each produce a new token.
  public func reloadToken(for artifact: StudioArtifact?) -> String {
    guard let artifact else { return "none" }
    return "\(artifact.id)#\(artifact.revision)#\(manualReloadCount)"
  }

  public func reload() {
    failureMessage = nil
    manualReloadCount += 1
  }

  /// Follows the agent: a newly filed artifact takes the selection; an
  /// existing selection survives re-files and reordering; a vanished selection
  /// falls back to the most recent.
  public func reconcileSelection(previous: [StudioArtifact], current: [StudioArtifact]) {
    let previousIds = Set(previous.map(\.id))
    let added = current.filter { !previousIds.contains($0.id) }
    if let newest = Self.mostRecentlyUpdated(in: added) {
      selectedArtifactId = newest.id
      failureMessage = nil
      return
    }
    if let selectedArtifactId, current.contains(where: { $0.id == selectedArtifactId }) {
      return
    }
    selectedArtifactId = Self.mostRecentlyUpdated(in: current)?.id
  }

  /// Recovers the variant from a Canvas selector when the page can't be asked —
  /// the scoped selector always names the artboard.
  public static func variantName(fromSelector selector: String) -> String? {
    guard let range = selector.range(of: ".studio-artboard[data-variant=\"") else { return nil }
    let rest = selector[range.upperBound...]
    var name = ""
    var iterator = rest.makeIterator()
    while let char = iterator.next() {
      if char == "\\" {
        if let next = iterator.next() { name.append(next) }
        continue
      }
      if char == "\"" { return name }
      name.append(char)
    }
    return nil
  }

  static func mostRecentlyUpdated(in artifacts: [StudioArtifact]) -> StudioArtifact? {
    artifacts.max {
      if $0.displayDate == $1.displayDate { return $0.id < $1.id }
      return $0.displayDate < $1.displayDate
    }
  }
}
