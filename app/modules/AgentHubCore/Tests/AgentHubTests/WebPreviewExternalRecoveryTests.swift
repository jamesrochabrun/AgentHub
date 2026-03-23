import Foundation
import Testing

@testable import AgentHubCore

@Suite("WebPreviewExternalRecovery")
struct WebPreviewExternalRecoveryTests {

  @Test("Initial recovery prefers dev server resolution")
  func initialRecoveryPrefersDevServerResolution() {
    let recovery = WebPreviewExternalRecovery.initial(projectPath: "/tmp/project")

    #expect(recovery.resolution == .devServer(projectPath: "/tmp/project"))
  }

  @Test("Recovered state uses static preview when one is available")
  func recoveredStateUsesStaticPreviewWhenAvailable() {
    let fallback = WebPreviewResolution.directFile(
      filePath: "/tmp/project/index.html",
      projectPath: "/tmp/project"
    )

    let recovery = WebPreviewExternalRecovery.recovered(
      agentURL: URL(string: "http://localhost:3000")!,
      error: "The operation couldn't be completed.",
      staticPreviewResolution: fallback
    )

    #expect(recovery.resolution == fallback)
  }

  @Test("Recovered state shows no-content guidance when no static fallback exists")
  func recoveredStateShowsNoContentGuidanceWhenNoStaticFallbackExists() {
    let recovery = WebPreviewExternalRecovery.recovered(
      agentURL: URL(string: "http://localhost:3000")!,
      error: "Connection refused",
      staticPreviewResolution: .noContent(reason: "No web-renderable files found in this project.")
    )

    guard case .noContent(let reason) = recovery.resolution else {
      Issue.record("Expected a no-content recovery state.")
      return
    }

    #expect(reason.contains("http://localhost:3000"))
    #expect(reason.contains("Connection refused"))
    #expect(reason.contains("No static HTML fallback was found in this project."))
  }

  @Test("A new agent URL resets recovery back to dev server resolution")
  func newAgentURLResetsRecoveryBackToDevServerResolution() {
    let recovered = WebPreviewExternalRecovery.recovered(
      agentURL: URL(string: "http://localhost:3000")!,
      error: "Connection refused",
      staticPreviewResolution: .noContent(reason: "No web-renderable files found in this project.")
    )
    let retried = WebPreviewExternalRecovery.initial(projectPath: "/tmp/project")

    #expect(recovered.resolution != .devServer(projectPath: "/tmp/project"))
    #expect(retried.resolution == .devServer(projectPath: "/tmp/project"))
  }
}
