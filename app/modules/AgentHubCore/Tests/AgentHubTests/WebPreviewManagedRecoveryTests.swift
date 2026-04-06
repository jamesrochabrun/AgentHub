import Foundation
import Testing

@testable import AgentHubCore

@Suite("WebPreviewManagedRecovery")
struct WebPreviewManagedRecoveryTests {

  @Test("Managed recovery keeps the preview on the dev-server path")
  func managedRecoveryKeepsDevServerResolution() {
    let recovery = WebPreviewManagedRecovery.recovered(
      projectPath: "/tmp/project",
      failedURL: URL(string: "http://localhost:3000")!,
      error: "Connection refused"
    )

    #expect(recovery.resolution == .devServer(projectPath: "/tmp/project"))
  }

  @Test("Managed recovery failure message includes the failed URL and error")
  func managedRecoveryFailureMessageIncludesURLAndError() {
    let recovery = WebPreviewManagedRecovery.recovered(
      projectPath: "/tmp/project",
      failedURL: URL(string: "http://localhost:3000")!,
      error: "Connection refused"
    )

    #expect(recovery.failureMessage.contains("http://localhost:3000"))
    #expect(recovery.failureMessage.contains("Connection refused"))
  }
}
