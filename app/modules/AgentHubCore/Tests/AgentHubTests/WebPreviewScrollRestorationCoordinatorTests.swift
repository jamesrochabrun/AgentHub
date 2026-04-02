import Foundation
import Testing

@testable import AgentHubCore

@Suite("WebPreviewScrollRestorationCoordinator")
struct WebPreviewScrollRestorationCoordinatorTests {

  @Test("Reset establishes the current reload token as baseline")
  func resetEstablishesBaseline() {
    let baselineToken = UUID()
    var coordinator = WebPreviewScrollRestorationCoordinator()

    coordinator.queueReload(token: UUID())
    _ = coordinator.beginCaptureIfNeeded()
    _ = coordinator.finishCapture(with: WebPreviewScrollPosition(x: 12, y: 24))
    coordinator.reset(to: baselineToken)

    #expect(coordinator.effectiveReloadToken == baselineToken)
    #expect(coordinator.pendingRequestedReloadToken == nil)
    #expect(coordinator.pendingScrollPosition == nil)
    #expect(!coordinator.isCapturingScrollPosition)
    #expect(!coordinator.suppressesSelectorRestore)
  }

  @Test("Queued reloads ignore the current baseline token")
  func queuedReloadsIgnoreCurrentBaselineToken() {
    let baselineToken = UUID()
    var coordinator = WebPreviewScrollRestorationCoordinator()
    coordinator.reset(to: baselineToken)

    coordinator.queueReload(token: baselineToken)

    #expect(coordinator.pendingRequestedReloadToken == nil)
    let startedCapture = coordinator.beginCaptureIfNeeded()
    #expect(!startedCapture)
  }

  @Test("Finishing capture applies the new token and stores the scroll position")
  func finishingCaptureAppliesPendingReload() {
    let baselineToken = UUID()
    let requestedToken = UUID()
    let scrollPosition = WebPreviewScrollPosition(x: 180, y: 960)
    var coordinator = WebPreviewScrollRestorationCoordinator()
    coordinator.reset(to: baselineToken)

    coordinator.queueReload(token: requestedToken)

    let startedCapture = coordinator.beginCaptureIfNeeded()
    #expect(startedCapture)
    #expect(coordinator.finishCapture(with: scrollPosition) == requestedToken)
    #expect(coordinator.effectiveReloadToken == requestedToken)
    #expect(coordinator.pendingScrollPosition == scrollPosition)
    #expect(coordinator.suppressesSelectorRestore)
  }

  @Test("Queued reloads coalesce while a capture is already in progress")
  func queuedReloadsCoalesceDuringCapture() {
    let baselineToken = UUID()
    let firstRequestedToken = UUID()
    let secondRequestedToken = UUID()
    let scrollPosition = WebPreviewScrollPosition(x: 48, y: 512)
    var coordinator = WebPreviewScrollRestorationCoordinator()
    coordinator.reset(to: baselineToken)

    coordinator.queueReload(token: firstRequestedToken)
    let startedCapture = coordinator.beginCaptureIfNeeded()
    #expect(startedCapture)

    coordinator.queueReload(token: secondRequestedToken)

    #expect(coordinator.finishCapture(with: scrollPosition) == secondRequestedToken)
    #expect(coordinator.effectiveReloadToken == secondRequestedToken)
    #expect(coordinator.pendingScrollPosition == scrollPosition)
    #expect(coordinator.pendingRequestedReloadToken == nil)
  }

  @Test("Consuming reload state clears selector suppression even without a scroll snapshot")
  func consumingReloadStateClearsSelectorSuppressionWithoutSnapshot() {
    let baselineToken = UUID()
    let requestedToken = UUID()
    var coordinator = WebPreviewScrollRestorationCoordinator()
    coordinator.reset(to: baselineToken)

    coordinator.queueReload(token: requestedToken)
    let startedCapture = coordinator.beginCaptureIfNeeded()
    #expect(startedCapture)
    #expect(coordinator.finishCapture(with: nil) == requestedToken)
    #expect(coordinator.suppressesSelectorRestore)

    #expect(coordinator.consumePendingScrollPosition() == nil)
    #expect(!coordinator.suppressesSelectorRestore)
  }
}

@Suite("WebPreviewScrollPosition")
struct WebPreviewScrollPositionTests {

  @Test("Parses JavaScript array results into a scroll position")
  func parsesJavaScriptArrayResults() {
    let position = WebPreviewScrollPosition.fromJavaScriptResult([
      NSNumber(value: 128.5),
      NSNumber(value: 640)
    ])

    #expect(position == WebPreviewScrollPosition(x: 128.5, y: 640))
  }

  @Test("Rejects malformed JavaScript results")
  func rejectsMalformedJavaScriptResults() {
    #expect(WebPreviewScrollPosition.fromJavaScriptResult(["invalid"]) == nil)
    #expect(WebPreviewScrollPosition.fromJavaScriptResult([NSNumber(value: Double.infinity), NSNumber(value: 1)]) == nil)
  }
}
