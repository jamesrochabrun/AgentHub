//
//  ResizeInteractionSuppression.swift
//  AgentHub
//

import Foundation

public final class ResizeInteractionSuppression {
  public static let shared = ResizeInteractionSuppression()

  private let lock = NSLock()
  private var activeResizeCount = 0
  private var suppressSelectionUntil: TimeInterval = 0

  private init() {}

  public func beginResize() {
    lock.lock()
    activeResizeCount += 1
    lock.unlock()
  }

  public func endResize() {
    lock.lock()
    activeResizeCount = max(0, activeResizeCount - 1)
    suppressSelectionUntil = max(suppressSelectionUntil, ProcessInfo.processInfo.systemUptime + 0.2)
    lock.unlock()
  }

  public var shouldSuppressSelection: Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeResizeCount > 0 || ProcessInfo.processInfo.systemUptime < suppressSelectionUntil
  }
}
