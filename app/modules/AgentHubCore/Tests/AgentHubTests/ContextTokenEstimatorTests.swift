import Foundation
import Testing

@testable import AgentHubCore

@Suite("Context token estimator")
struct ContextTokenEstimatorTests {

  private let estimator = ContextTokenEstimator()

  @Test("Zero bytes estimates zero tokens")
  func zeroBytes() {
    #expect(estimator.estimatedTokens(forByteCount: 0) == 0)
    #expect(estimator.estimatedTokens(forByteCount: -10) == 0)
  }

  @Test("bytes/4 with safety multiplier, rounded up")
  func estimateFormula() {
    // 4000 bytes / 4 = 1000 tokens × 1.15 = 1150.
    #expect(estimator.estimatedTokens(forByteCount: 4000) == 1150)
    // 1 byte → 0.2875 → rounds up to 1.
    #expect(estimator.estimatedTokens(forByteCount: 1) == 1)
    // 10 bytes → 2.875 → 3.
    #expect(estimator.estimatedTokens(forByteCount: 10) == 3)
  }

  @Test("Estimate is monotonic")
  func monotonic() {
    var previous = 0
    for bytes in stride(from: 0, through: 100_000, by: 7919) {
      let estimate = estimator.estimatedTokens(forByteCount: bytes)
      #expect(estimate >= previous)
      previous = estimate
    }
  }
}
