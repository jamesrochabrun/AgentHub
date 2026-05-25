import Testing

@testable import AgentHubCore

@MainActor
@Suite("EmbeddedSidePanelExpansionState")
struct EmbeddedSidePanelExpansionStateTests {
  @Test("Toggle expands and collapses the same payload")
  func toggleExpandsAndCollapsesSamePayload() {
    let state = EmbeddedSidePanelExpansionState<String>()

    state.toggle(for: "web")

    #expect(state.isExpanded(for: "web"))
    #expect(state.expandedPayload == "web")

    state.toggle(for: "web")

    #expect(!state.isExpanded(for: "web"))
    #expect(state.expandedPayload == nil)
  }

  @Test("Toggling another payload transfers expansion")
  func togglingAnotherPayloadTransfersExpansion() {
    let state = EmbeddedSidePanelExpansionState<String>()

    state.toggle(for: "web")
    state.toggle(for: "diff")

    #expect(!state.isExpanded(for: "web"))
    #expect(state.isExpanded(for: "diff"))
  }

  @Test("Collapse if expanded only affects matching payload")
  func collapseIfExpandedOnlyAffectsMatchingPayload() {
    let state = EmbeddedSidePanelExpansionState<String>()

    state.toggle(for: "web")
    state.collapse(ifExpanded: "diff")

    #expect(state.isExpanded(for: "web"))

    state.collapse(ifExpanded: "web")

    #expect(state.expandedPayload == nil)
  }

  @Test("Reconcile clears stale expansion")
  func reconcileClearsStaleExpansion() {
    let state = EmbeddedSidePanelExpansionState<String>()

    state.toggle(for: "web")
    state.reconcile(currentPayload: "web")

    #expect(state.isExpanded(for: "web"))

    state.reconcile(currentPayload: "diff")

    #expect(state.expandedPayload == nil)
  }
}
