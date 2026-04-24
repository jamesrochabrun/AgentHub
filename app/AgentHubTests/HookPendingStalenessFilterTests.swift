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

  @Test("preserves hook pending when JSONL activity is within the epsilon window")
  func sameSecondClockSkewStillLive() {
    // Legacy whole-second hook timestamp truncates to 10:30:45.000Z while
    // JSONL's millisecond-precision lastActivityAt is 10:30:45.400Z. Without
    // the epsilon this would incorrectly drop a live pending.
    let decisionTime = Date()
    let pending = makePending(at: decisionTime)
    let result = HookPendingStalenessFilter.filter(
      hookPending: pending,
      lastActivityAt: decisionTime.addingTimeInterval(0.4)
    )
    #expect(result?.toolUseId == "tu-1")
  }

  @Test("drops hook pending once JSONL has advanced past the epsilon window")
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
