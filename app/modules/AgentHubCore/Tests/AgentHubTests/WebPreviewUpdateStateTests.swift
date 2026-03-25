import Foundation
import Testing

@testable import AgentHubCore

@Suite("WebPreviewUpdateState")
struct WebPreviewUpdateStateTests {

  @Test("Non-edit mode hides manual update")
  @MainActor
  func nonEditModeHidesManualUpdate() {
    let state = WebPreviewUpdateState.resolve(
      resolution: .directFile(filePath: "/project/index.html", projectPath: "/project"),
      serverState: .idle,
      isEditMode: false
    )

    #expect(!state.isVisible)
    #expect(!state.isEnabled)
  }

  @Test("Edit mode enables manual update for direct-file previews")
  @MainActor
  func directFilePreviewsEnableManualUpdateInEditMode() {
    let state = WebPreviewUpdateState.resolve(
      resolution: .directFile(filePath: "/project/index.html", projectPath: "/project"),
      serverState: .idle,
      isEditMode: true
    )

    #expect(state.isVisible)
    #expect(state.isEnabled)
    #expect(state.detailText == "Design and code preview updates are manual. Save changes, then press Reload.")
  }

  @Test("Edit mode enables manual update for ready dev-server previews")
  @MainActor
  func readyDevServerPreviewsEnableManualUpdate() {
    let state = WebPreviewUpdateState.resolve(
      resolution: .devServer(projectPath: "/project"),
      serverState: .ready(url: URL(string: "http://localhost:3000")!),
      isEditMode: true
    )

    #expect(state.isVisible)
    #expect(state.isEnabled)
    #expect(state.detailText == "Design and code preview updates are manual. Save changes, then press Reload.")
  }

  @Test("Unavailable preview states disable manual update in edit mode")
  @MainActor
  func unavailablePreviewStatesDisableManualUpdate() {
    let loadingState = WebPreviewUpdateState.resolve(
      resolution: .devServer(projectPath: "/project"),
      serverState: .starting(message: "Starting dev server..."),
      isEditMode: true
    )
    let emptyState = WebPreviewUpdateState.resolve(
      resolution: .noContent(reason: "No web-renderable files found in this project."),
      serverState: .idle,
      isEditMode: true
    )

    #expect(loadingState.isVisible)
    #expect(!loadingState.isEnabled)
    #expect(loadingState.detailText == "Reload will be available when the preview finishes loading.")
    #expect(emptyState.isVisible)
    #expect(!emptyState.isEnabled)
    #expect(emptyState.detailText == "No web-renderable files found in this project.")
  }

  @Test("Perform update flushes pending writes before reload")
  @MainActor
  func performUpdateFlushesPendingWritesBeforeReload() async {
    var events: [String] = []
    let state = WebPreviewUpdateState.available(detail: "Design and code preview reloads are manual.")

    await state.performUpdate(
      flushPendingWrites: {
        events.append("flush")
      },
      reload: {
        events.append("reload")
      }
    )

    #expect(events == ["flush", "reload"])
  }

  @Test("Perform update does nothing when hidden")
  @MainActor
  func performUpdateDoesNothingWhenHidden() async {
    var events: [String] = []
    let state = WebPreviewUpdateState.hidden

    await state.performUpdate(
      flushPendingWrites: {
        events.append("flush")
      },
      reload: {
        events.append("reload")
      }
    )

    #expect(events.isEmpty)
  }
}
