import Testing

@testable import AgentHubCore

@MainActor
@Suite("EmbeddedSidePanelPresentationState")
struct EmbeddedSidePanelPresentationStateTests {
  @Test("Open presents shell before mounting content")
  func openPresentsShellBeforeMountingContent() {
    let state = EmbeddedSidePanelPresentationState<String>()

    let id = state.open("github")

    #expect(state.shellPayload == "github")
    #expect(state.mountedPayload == nil)
    #expect(state.currentPayload == "github")

    state.completeDeferredTransition(id: id)

    #expect(state.shellPayload == "github")
    #expect(state.mountedPayload == "github")
  }

  @Test("Close unmounts content before removing shell")
  func closeUnmountsContentBeforeRemovingShell() {
    let state = EmbeddedSidePanelPresentationState<String>()
    let openID = state.open("diff")
    state.completeDeferredTransition(id: openID)

    let closeID = state.close()

    #expect(state.shellPayload == "diff")
    #expect(state.mountedPayload == nil)

    state.completeDeferredTransition(id: closeID)

    #expect(state.shellPayload == nil)
    #expect(state.mountedPayload == nil)
  }

  @Test("Stale deferred transitions are ignored")
  func staleDeferredTransitionsAreIgnored() {
    let state = EmbeddedSidePanelPresentationState<String>()

    let firstOpenID = state.open("web")
    let closeID = state.close()
    let secondOpenID = state.open("github")

    state.completeDeferredTransition(id: firstOpenID)
    state.completeDeferredTransition(id: closeID)

    #expect(state.shellPayload == "github")
    #expect(state.mountedPayload == nil)

    state.completeDeferredTransition(id: secondOpenID)

    #expect(state.shellPayload == "github")
    #expect(state.mountedPayload == "github")
  }
}
