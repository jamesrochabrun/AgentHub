//
//  TerminalUILogger.swift
//  AgentHub
//

import Foundation
import OSLog

public enum TerminalUILogger {
  public static let terminal = Logger(subsystem: "com.agenthub", category: "Terminal")
  // TODO: Remove panel latency logs before merging the regular terminal multiwindow PR.
  public static let panelLatencyPrefix = "[TerminalPanelLatency]"

  public static func latencyTimestamp() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  public static func elapsedMilliseconds(since start: TimeInterval) -> String {
    elapsedMilliseconds(from: start, to: latencyTimestamp())
  }

  public static func elapsedMilliseconds(from start: TimeInterval, to end: TimeInterval) -> String {
    String(format: "%.1fms", max(0, end - start) * 1_000)
  }
}
