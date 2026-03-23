import Testing

@testable import AgentHubCore

@Suite("WebPreviewExternalLoadFailurePolicy")
struct WebPreviewExternalLoadFailurePolicyTests {

  @Test("Falls back on the initial external load for real connectivity failures")
  func fallsBackOnInitialLoadConnectivityFailures() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
      hasLoadedExternalContent: false,
      error: "The operation couldn’t be completed. Connection refused"
    )

    #expect(shouldFallback)
  }

  @Test("Does not fall back for benign cancelled navigation errors")
  func doesNotFallbackForCancelledNavigationErrors() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
      hasLoadedExternalContent: false,
      error: "The operation couldn’t be completed. (WebKitErrorDomain error 102.) Frame load interrupted"
    )

    #expect(!shouldFallback)
  }

  @Test("Does not fall back after the external preview has already loaded once")
  func doesNotFallbackAfterSuccessfulExternalLoad() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
      hasLoadedExternalContent: true,
      error: "The operation couldn’t be completed. Connection refused"
    )

    #expect(!shouldFallback)
  }
}
