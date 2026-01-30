//
//  GlobalStatsService.swift
//  AgentHub
//
//  Created by Assistant on 1/13/26.
//

import Foundation
import Observation
import os

// MARK: - GlobalStatsService

/// Service that monitors and provides global Claude Code usage statistics
@Observable
public final class GlobalStatsService: @unchecked Sendable {

  // MARK: - Properties

  /// The parsed global stats cache
  public private(set) var stats: GlobalStatsCache = GlobalStatsCache()

  /// Whether the stats file exists
  public private(set) var isAvailable: Bool = false

  /// Last time stats were updated
  public private(set) var lastUpdated: Date?

  private let statsFilePath: String
  private var fileWatcher: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1

  // MARK: - Computed Properties

  /// Total tokens across all models (input + output only, excludes cache)
  public var totalTokens: Int {
    stats.modelUsage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
  }

  /// Formatted total tokens (e.g., "10.5M", "150K")
  public var formattedTotalTokens: String {
    formatTokenCount(totalTokens)
  }

  /// Estimated total cost using CostCalculator pricing
  public var estimatedCost: Decimal {
    var totalCost: Decimal = 0
    for (modelName, usage) in stats.modelUsage {
      let breakdown = CostCalculator.calculate(
        model: modelName,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        cacheReadTokens: usage.cacheReadInputTokens,
        cacheCreationTokens: usage.cacheCreationInputTokens
      )
      totalCost += breakdown.totalCost
    }
    return totalCost
  }

  /// Formatted cost string (e.g., "$127.45")
  public var formattedCost: String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    return formatter.string(from: estimatedCost as NSDecimalNumber) ?? "$0.00"
  }

  /// Today's activity stats
  public var todayActivity: DailyActivity? {
    let today = formatDateForComparison(Date())
    return stats.dailyActivity.first { $0.date == today }
  }

  /// Number of days with at least one session
  public var daysActive: Int {
    stats.dailyActivity.count
  }

  /// First session date formatted
  public var firstSessionFormatted: String? {
    guard let firstDate = stats.firstSessionDate,
          let date = parseISO8601Date(firstDate) else {
      return nil
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter.string(from: date)
  }

  /// Model-specific stats
  public var modelStats: [(name: String, usage: ModelUsage, cost: Decimal)] {
    stats.modelUsage.map { (modelName, usage) in
      let breakdown = CostCalculator.calculate(
        model: modelName,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        cacheReadTokens: usage.cacheReadInputTokens,
        cacheCreationTokens: usage.cacheCreationInputTokens
      )
      return (name: formatModelName(modelName), usage: usage, cost: breakdown.totalCost)
    }.sorted { $0.cost > $1.cost }
  }

  // MARK: - Initialization

  public init(claudePath: String = "~/.claude") {
    let expandedPath = NSString(string: claudePath).expandingTildeInPath
    self.statsFilePath = "\(expandedPath)/stats-cache.json"

    loadStats()
    startWatching()
  }

  deinit {
    stopWatching()
  }

  // MARK: - Public API

  /// Manually refresh stats
  public func refresh() {
    loadStats()
  }

  // MARK: - Private Methods

  private func loadStats() {
    guard FileManager.default.fileExists(atPath: statsFilePath) else {
      isAvailable = false
      return
    }

    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: statsFilePath))
      stats = try JSONDecoder().decode(GlobalStatsCache.self, from: data)
      isAvailable = true
      lastUpdated = Date()
    } catch {
      AppLogger.stats.error("Failed to parse stats: \(error.localizedDescription)")
      isAvailable = false
    }
  }

  private func startWatching() {
    guard FileManager.default.fileExists(atPath: statsFilePath) else {
      // Try again later when file might exist
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
        self?.startWatching()
      }
      return
    }

    fileDescriptor = open(statsFilePath, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      AppLogger.stats.error("Could not open file for watching")
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend, .attrib],
      queue: DispatchQueue.global(qos: .utility)
    )

    source.setEventHandler { [weak self] in
      DispatchQueue.main.async {
        self?.loadStats()
      }
    }

    source.setCancelHandler { [weak self] in
      if let fd = self?.fileDescriptor, fd >= 0 {
        close(fd)
      }
    }

    source.resume()
    fileWatcher = source
  }

  private func stopWatching() {
    fileWatcher?.cancel()
    fileWatcher = nil
  }

  // MARK: - Formatting Helpers

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000_000 {
      let billions = Double(count) / 1_000_000_000
      return String(format: "%.1fB", billions)
    } else if count >= 1_000_000 {
      let millions = Double(count) / 1_000_000
      return String(format: "%.1fM", millions)
    } else if count >= 1_000 {
      let thousands = Double(count) / 1_000
      return String(format: "%.1fK", thousands)
    }
    return "\(count)"
  }

  private func formatModelName(_ model: String) -> String {
    if model.lowercased().contains("opus") {
      return "Opus"
    } else if model.lowercased().contains("sonnet") {
      return "Sonnet"
    } else if model.lowercased().contains("haiku") {
      return "Haiku"
    }
    return model
  }

  private func formatDateForComparison(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")  // Match CLI format
    return formatter.string(from: date)
  }

  private func parseISO8601Date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    // Try without fractional seconds
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
