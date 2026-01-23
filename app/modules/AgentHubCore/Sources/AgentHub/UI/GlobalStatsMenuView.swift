//
//  GlobalStatsMenuView.swift
//  AgentHub
//
//  Created by Assistant on 1/13/26.
//

import SwiftUI

// MARK: - GlobalStatsMenuView

/// View for displaying global Claude Code stats in a menu bar dropdown
public struct GlobalStatsMenuView: View {
  let service: GlobalStatsService
  let showQuitButton: Bool

  public init(service: GlobalStatsService, showQuitButton: Bool = true) {
    self.service = service
    self.showQuitButton = showQuitButton
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if service.isAvailable {
        // Header
        headerSection

        Divider()
          .padding(.vertical, 8)

        // Total stats
        totalStatsSection

        Divider()
          .padding(.vertical, 8)

        // Today's activity
        todaySection

        Divider()
          .padding(.vertical, 8)

        // Model breakdown
        modelBreakdownSection

        Divider()
          .padding(.vertical, 8)

        // Footer with refresh
        footerSection

        // Quit button at the bottom
        if showQuitButton {
          Divider()
            .padding(.vertical, 8)

          Button("Quit app") {
            NSApplication.shared.terminate(nil)
          }
          .buttonStyle(.plain)
          .font(.caption)
        }
      } else {
        Text("Stats not available")
          .foregroundColor(.secondary)
          .padding()
      }
    }
    .padding(12)
    .frame(width: 280)
  }

  // MARK: - Header Section

  private var headerSection: some View {
    HStack {
      Image(systemName: "chart.bar.fill")
        .foregroundColor(.brandPrimary)
      Text("Claude Code Stats")
        .font(.headline)
      Spacer()
    }
  }

  // MARK: - Total Stats Section

  private var totalStatsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      StatRow(
        label: "Total Tokens",
        value: service.formattedTotalTokens,
        icon: "number.circle.fill"
      )

      StatRow(
        label: "Estimated Cost",
        value: service.formattedCost,
        icon: "dollarsign.circle.fill"
      )

      StatRow(
        label: "Sessions",
        value: "~\(service.stats.totalSessions)",
        icon: "terminal.fill"
      )

      StatRow(
        label: "Messages",
        value: formatNumber(service.stats.totalMessages),
        icon: "message.fill"
      )

      if service.daysActive > 0 {
        StatRow(
          label: "Days Active",
          value: "\(service.daysActive)",
          icon: "calendar"
        )
      }
    }
  }

  // MARK: - Today Section

  private var todaySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Today")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)

      if let today = service.todayActivity {
        HStack(spacing: 16) {
          MiniStat(value: "\(today.messageCount)", label: "msgs")
          MiniStat(value: "\(today.sessionCount)", label: "sessions")
          MiniStat(value: "\(today.toolCallCount)", label: "tools")
        }
      } else {
        Text("No activity yet")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Model Breakdown Section

  private var modelBreakdownSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("By Model")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)

      ForEach(service.modelStats, id: \.name) { model in
        HStack {
          Text(model.name)
            .font(.caption)
          Spacer()
          Text(formatTokenCount(model.usage.inputTokens + model.usage.outputTokens))
            .font(.caption)
            .foregroundColor(.secondary)
          Text(formatCost(model.cost))
            .font(.caption)
            .fontWeight(.medium)
        }
      }
    }
  }

  // MARK: - Footer Section

  private var footerSection: some View {
    HStack {
      if let lastUpdated = service.lastUpdated {
        Text("Updated \(lastUpdated, style: .relative) ago")
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      Spacer()

      Button(action: { service.refresh() }) {
        Image(systemName: "arrow.clockwise")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .help("Refresh stats")
    }
  }

  // MARK: - Helpers

  private func formatNumber(_ num: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
  }

  private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000_000 {
      return String(format: "%.1fB", Double(count) / 1_000_000_000)
    } else if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
      return String(format: "%.0fK", Double(count) / 1_000)
    }
    return "\(count)"
  }

  private func formatCost(_ cost: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    return formatter.string(from: cost as NSDecimalNumber) ?? "$0"
  }
}

// MARK: - StatRow

private struct StatRow: View {
  let label: String
  let value: String
  let icon: String

  var body: some View {
    HStack {
      Image(systemName: icon)
        .foregroundColor(.brandPrimary)
        .frame(width: 16)
      Text(label)
        .font(.caption)
      Spacer()
      Text(value)
        .font(.caption)
        .fontWeight(.medium)
    }
  }
}

// MARK: - MiniStat

private struct MiniStat: View {
  let value: String
  let label: String

  var body: some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .fontWeight(.semibold)
      Text(label)
        .font(.caption2)
        .foregroundColor(.secondary)
    }
  }
}

// MARK: - Preview

#if DEBUG
#Preview {
  GlobalStatsMenuView(service: GlobalStatsService())
}
#endif
