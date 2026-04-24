import Foundation
import Testing
@testable import AgentHubCore

@Suite("HookPendingStalenessFilter")
struct HookPendingStalenessFilterTests {

  private func makePending(at date: Date) -> SessionJSONLParser.PendingToolInfo {
    SessionJSONLParser.PendingToolInfo(
      toolName: "Edit",
      toolUseId: "tu-1",
      timestamp: date,
      input: nil,
      codeChangeInput: nil
    )
  }

  @Test("nil hook pending passes through")
  func nilHookPending() {
    let result = HookPendingStalenessFilter.filter(
      hookPending: nil,
      lastActivityAt: Date()
    )
    #expect(result == nil)
  }

  @Test("surfaces hook pending when no JSONL activity has been seen")
  func noActivity() {
    let pending = makePending(at: Date())
    let result = HookPendingStalenessFilter.filter(
      hookPending: pending,
      lastActivityAt: nil
    )
    #expect(result?.toolUseId == "tu-1")
  }

  @Test("surfaces hook pending when JSONL activity is older than the hook decision")
  func jsonlStaleRelativeToHook() {
    let decisionTime = Date()
    let pending = makePending(at: decisionTime)
    let result = HookPendingStalenessFilter.filter(
      hookPending: pending,
      lastActivityAt: decisionTime.addingTimeInterval(-5)
    )
    #expect(result?.toolUseId == "tu-1")
  }

  @Test("drops hook pending when JSONL has newer activity — turn must have committed")
  func jsonlProvesResolution() {
    let decisionTime = Date()
    let pending = makePending(at: decisionTime)
    let result = HookPendingStalenessFilter.filter(
      hookPending: pending,
      lastActivityAt: decisionTime.addingTimeInterval(10)
    )
    #expect(result == nil)
  }

  @Test("preserves hook pending within cross-process clock skew")
  func smallClockSkewPreserved() {
    // Cross-process skew between the Python hook and Claude's Node process
    // is typically in the low-ms range. 50ms is safely inside the epsilon;
    // a live pending must not be dropped for that.
    let decisionTime = Date()
    let pending = makePending(at: decisionTime)
    let result = HookPendingStalenessFilter.filter(
      hookPending: pending,
      lastActivityAt: decisionTime.addingTimeInterval(0.05)
    )
    #expect(result?.toolUseId == "tu-1")
  }

  @Test("drops hook pending for fast-turn resolution just past the epsilon")
  func fastTurnResolutionIsDetected() {
    // A user can approve and a tool can commit inside a few hundred ms.
    // Once JSONL activity has advanced beyond the epsilon, the sidecar's
    // pending must be treated as stale — this is exactly the "fast Bash
    // turn leaves the UI stuck on pending" case.
    let decisionTime = Date()
    let pending = makePending(at: decisionTime)
    let result = HookPendingStalenessFilter.filter(
      hookPending: pending,
      lastActivityAt: decisionTime.addingTimeInterval(0.3)
    )
    #expect(result == nil)
  }

  @Test("drops hook pending when JSONL is seconds past the hook decision")
  func beyondEpsilonIsStale() {
    let decisionTime = Date()
    let pending = makePending(at: decisionTime)
    let result = HookPendingStalenessFilter.filter(
      hookPending: pending,
      lastActivityAt: decisionTime.addingTimeInterval(1.5)
    )
    #expect(result == nil)
  }
}
