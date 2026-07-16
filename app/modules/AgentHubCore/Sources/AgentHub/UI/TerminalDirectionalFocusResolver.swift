//
//  TerminalDirectionalFocusResolver.swift
//  AgentHub
//

import CoreGraphics

public enum TerminalFocusDirection: Sendable {
  case left
  case right
  case up
  case down
}

public enum TerminalDirectionalFocusResolver {
  public static func target<ID: Hashable>(
    from currentID: ID,
    frames: [ID: CGRect],
    direction: TerminalFocusDirection
  ) -> ID? {
    guard let currentFrame = frames[currentID] else { return nil }
    let currentCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

    let candidates = frames.compactMap { id, frame -> Candidate<ID>? in
      guard id != currentID else { return nil }
      let center = CGPoint(x: frame.midX, y: frame.midY)
      let primaryDistance: Double
      let perpendicularDistance: Double
      let overlaps: Bool

      switch direction {
      case .left:
        guard center.x < currentCenter.x else { return nil }
        primaryDistance = currentCenter.x - center.x
        perpendicularDistance = abs(currentCenter.y - center.y)
        overlaps = frame.intersectsVertically(with: currentFrame)
      case .right:
        guard center.x > currentCenter.x else { return nil }
        primaryDistance = center.x - currentCenter.x
        perpendicularDistance = abs(currentCenter.y - center.y)
        overlaps = frame.intersectsVertically(with: currentFrame)
      case .up:
        guard center.y < currentCenter.y else { return nil }
        primaryDistance = currentCenter.y - center.y
        perpendicularDistance = abs(currentCenter.x - center.x)
        overlaps = frame.intersectsHorizontally(with: currentFrame)
      case .down:
        guard center.y > currentCenter.y else { return nil }
        primaryDistance = center.y - currentCenter.y
        perpendicularDistance = abs(currentCenter.x - center.x)
        overlaps = frame.intersectsHorizontally(with: currentFrame)
      }

      let score = primaryDistance + perpendicularDistance * (overlaps ? 0.1 : 1)
      return Candidate(
        id: id,
        score: score,
        primaryDistance: primaryDistance,
        x: frame.minX,
        y: frame.minY
      )
    }

    return candidates.min(by: Candidate.isOrderedBefore)?.id
  }
}

private struct Candidate<ID> {
  let id: ID
  let score: Double
  let primaryDistance: Double
  let x: Double
  let y: Double

  static func isOrderedBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.score != rhs.score { return lhs.score < rhs.score }
    if lhs.primaryDistance != rhs.primaryDistance {
      return lhs.primaryDistance < rhs.primaryDistance
    }
    if lhs.y != rhs.y { return lhs.y < rhs.y }
    return lhs.x < rhs.x
  }
}

private extension CGRect {
  func intersectsVertically(with other: CGRect) -> Bool {
    minY < other.maxY && maxY > other.minY
  }

  func intersectsHorizontally(with other: CGRect) -> Bool {
    minX < other.maxX && maxX > other.minX
  }
}
