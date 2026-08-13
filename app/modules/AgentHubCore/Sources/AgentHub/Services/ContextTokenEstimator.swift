//
//  ContextTokenEstimator.swift
//  AgentHub
//
//  Model-agnostic approximate token cost for curated context. Deliberately
//  overestimates (code tokenizes denser than prose) so budget warnings err
//  toward caution. All values surfaced to users must be labeled approximate.
//

import Foundation

public protocol ContextTokenEstimating: Sendable {
  func estimatedTokens(forByteCount byteCount: Int) -> Int
}

public struct ContextTokenEstimator: ContextTokenEstimating {
  public static let bytesPerToken = 4.0
  public static let safetyMultiplier = 1.15

  public init() {}

  public func estimatedTokens(forByteCount byteCount: Int) -> Int {
    guard byteCount > 0 else { return 0 }
    return Int((Double(byteCount) / Self.bytesPerToken * Self.safetyMultiplier).rounded(.up))
  }
}
