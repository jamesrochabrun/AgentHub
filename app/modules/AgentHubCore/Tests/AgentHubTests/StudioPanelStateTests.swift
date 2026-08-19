import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("StudioPanelState")
struct StudioPanelStateTests {
  private let older = makeStudioCanvas(id: "older", createdAt: Date(timeIntervalSince1970: 100))
  private let newer = makeStudioDocument(id: "newer", createdAt: Date(timeIntervalSince1970: 200))

  @Test("With no explicit selection, the most recently updated artifact is shown")
  func defaultsToMostRecentlyUpdated() {
    let state = StudioPanelState()
    #expect(state.selectedArtifact(in: [older, newer])?.id == "newer")

    let refiled = makeStudioCanvas(id: "older", createdAt: Date(timeIntervalSince1970: 300)).replacing(older)
    #expect(refiled.displayDate == Date(timeIntervalSince1970: 300))
    #expect(state.selectedArtifact(in: [refiled, newer])?.id == "older")
  }

  @Test("An explicit selection wins while it exists, then falls back")
  func explicitSelectionWins() {
    let state = StudioPanelState()
    state.selectedArtifactId = "older"
    #expect(state.selectedArtifact(in: [older, newer])?.id == "older")
    #expect(state.selectedArtifact(in: [newer])?.id == "newer")
    #expect(state.selectedArtifact(in: []) == nil)
  }

  @Test("Reload token changes on artifact switch, revision bump, and manual reload")
  func reloadToken() {
    let state = StudioPanelState()
    #expect(state.reloadToken(for: nil) == "none")
    let base = state.reloadToken(for: older)
    #expect(state.reloadToken(for: newer) != base)
    let bumped = makeStudioCanvas(id: "older", createdAt: older.createdAt).replacing(older)
    #expect(state.reloadToken(for: bumped) != base)
    state.failureMessage = "x"
    state.reload()
    #expect(state.reloadToken(for: older) != base)
    #expect(state.failureMessage == nil)
  }

  @Test("Selection follows a newly filed artifact, survives re-files, falls back when deleted")
  func reconcileSelection() {
    let state = StudioPanelState()
    state.selectedArtifactId = "older"

    // Re-file of the selected item: selection sticks.
    let refiled = makeStudioCanvas(id: "older", createdAt: Date(timeIntervalSince1970: 500)).replacing(older)
    state.reconcileSelection(previous: [older, newer], current: [refiled, newer])
    #expect(state.selectedArtifactId == "older")

    // A brand-new artifact takes over.
    let brandNew = makeStudioDocument(id: "brand-new", createdAt: Date(timeIntervalSince1970: 50))
    state.reconcileSelection(previous: [refiled, newer], current: [refiled, newer, brandNew])
    #expect(state.selectedArtifactId == "brand-new")

    // Deleting the selected one falls back to the most recently updated.
    state.reconcileSelection(previous: [refiled, newer, brandNew], current: [refiled, newer])
    #expect(state.selectedArtifactId == "older")
  }

  @Test("Variant name is recovered from a scoped selector, including escaped quotes")
  func variantFromSelector() {
    #expect(StudioPanelState.variantName(fromSelector: ".studio-artboard[data-variant=\"ghost\"] > button.btn") == "ghost")
    #expect(StudioPanelState.variantName(fromSelector: ".studio-artboard[data-variant=\"say \\\"hi\\\"\"] i") == "say \"hi\"")
    #expect(StudioPanelState.variantName(fromSelector: "body > div > button") == nil)
  }
}
