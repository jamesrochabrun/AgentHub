import Darwin
import Foundation
import Testing

@testable import AgentHubCore

@Suite("FileDescriptorLimits")
struct FileDescriptorLimitsTests {

  @Test("Raising the soft limit reaches the target (bounded by the hard limit)")
  func raisesSoftLimitToTarget() {
    let result = FileDescriptorLimits.raiseSoftLimit()

    var limits = rlimit()
    #expect(getrlimit(RLIMIT_NOFILE, &limits) == 0)

    let expectedFloor = min(limits.rlim_max, FileDescriptorLimits.targetSoftLimit)
    #expect(limits.rlim_cur >= expectedFloor)
    #expect(result == limits.rlim_cur)
  }

  @Test("Raising is idempotent and never lowers an already-higher limit")
  func neverLowersExistingLimit() {
    let first = FileDescriptorLimits.raiseSoftLimit()
    let second = FileDescriptorLimits.raiseSoftLimit()
    #expect(first != nil)
    #expect(second != nil)
    if let first, let second {
      #expect(second >= first)
    }

    var limits = rlimit()
    #expect(getrlimit(RLIMIT_NOFILE, &limits) == 0)
    #expect(limits.rlim_cur == second)
  }
}
