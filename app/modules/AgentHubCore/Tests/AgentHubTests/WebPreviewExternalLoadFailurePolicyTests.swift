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

  @Test("Falls back on connection refused even after a successful external load")
  func fallsBackOnConnectionRefusedEvenAfterSuccessfulLoad() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
      hasLoadedExternalContent: true,
      error: "The operation couldn’t be completed. Connection refused"
    )

    #expect(shouldFallback)
  }

  @Test("Falls back on NSURLErrorCannotConnectToHost even when reported as interrupted")
  func fallsBackWhenHostUnreachableInsideInterruptedFrame() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
      hasLoadedExternalContent: false,
      error: "NSURLErrorCannotConnectToHost: Frame load interrupted"
    )

    #expect(shouldFallback)
  }

  @Test("Falls back on 'Could not connect to the server' regardless of prior success")
  func fallsBackOnCouldNotConnectError() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
      hasLoadedExternalContent: true,
      error: "Could not connect to the server."
    )

    #expect(shouldFallback)
  }

  @Test("Still ignores pure HMR-style cancelled errors after a successful load")
  func ignoresPureHMRCancelledErrorAfterSuccessfulLoad() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
      hasLoadedExternalContent: true,
      error: "The operation couldn’t be completed. (WebKitErrorDomain error 102.) Frame load interrupted"
    )

    #expect(!shouldFallback)
  }

  @Test("Managed preview falls back on connection failures")
  func managedPreviewFallsBackOnConnectionFailures() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallbackForManagedPreview(
      error: "NSURLErrorCannotConnectToHost"
    )

    #expect(shouldFallback)
  }

  @Test("Managed preview ignores cancelled navigation errors")
  func managedPreviewIgnoresCancelledNavigationErrors() {
    let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallbackForManagedPreview(
      error: "The operation couldn’t be completed. (WebKitErrorDomain error 102.) Frame load interrupted"
    )

    #expect(!shouldFallback)
  }
}
