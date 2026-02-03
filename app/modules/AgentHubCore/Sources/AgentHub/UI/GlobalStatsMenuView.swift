//
//  GlobalStatsMenuView.swift
//  AgentHub
//
//  Created by Assistant on 1/13/26.
//

import SwiftUI

// MARK: - GlobalStatsMenuView

/// View for displaying global Claude Code or Codex stats in a menu bar dropdown
public struct GlobalStatsMenuView: View {
  let claudeService: GlobalStatsService
  let codexService: CodexGlobalStatsService?
  let sessionsViewModel: CLISessionsViewModel?
  let showQuitButton: Bool

  @AppStorage(AgentHubDefaults.selectedStatsProvider)
  private var selectedProviderRaw: String = SessionProviderKind.claude.rawValue

  private var selectedProvider: SessionProviderKind {
    get { SessionProviderKind(rawValue: selectedProviderRaw) ?? .claude }
  }

  public init(
    claudeService: GlobalStatsService,
    codexService: CodexGlobalStatsService? = nil,
    sessionsViewModel: CLISessionsViewModel? = nil,
    showQuitButton: Bool = true
  ) {
    self.claudeService = claudeService
    self.codexService = codexService
    self.sessionsViewModel = sessionsViewModel
    self.showQuitButton = showQuitButton
  }

  /// Backwards-compatible initializer
  public init(
    service: GlobalStatsService,
    sessionsViewModel: CLISessionsViewModel? = nil,
    showQuitButton: Bool = true
  ) {
    self.claudeService = service
    self.codexService = nil
    self.sessionsViewModel = sessionsViewModel
    self.showQuitButton = showQuitButton
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Segmented control at top (only if Codex service provided)
      if codexService != nil {
        StatsProviderSegmentedControl(
          selectedProvider: Binding(
            get: { selectedProvider },
            set: { selectedProviderRaw = $0.rawValue }
          ),
          claudeSessionCount: claudeService.stats.totalSessions,
          codexSessionCount: codexService?.totalSessions ?? 0
        )
        .padding(.bottom, 12)
      }

      if selectedProvider == .claude {
        claudeStatsContent
      } else {
        codexStatsContent
      }
    }
    .padding(12)
    .frame(width: 280)
    .onAppear {
      sessionsViewModel?.refreshOrphanedProcessCount()
    }
    .onDisappear {
      codexService?.cancelLoading()
    }
  }

  // MARK: - Claude Stats Content

  @ViewBuilder
  private var claudeStatsContent: some View {
    if claudeService.isAvailable {
      // Header
      headerSection(title: "Claude Stats", icon: "chart.bar.fill", provider: .claude)

      Divider()
        .padding(.vertical, 8)

      // Total stats
      claudeTotalStatsSection

      Divider()
        .padding(.vertical, 8)

      // Today's activity (only shown when data exists)
      if claudeService.todayActivity != nil {
        claudeTodaySection

        Divider()
          .padding(.vertical, 8)
      }

      // Model breakdown
      claudeModelBreakdownSection

      // Orphaned processes (only if any exist)
      if let vm = sessionsViewModel, vm.orphanedProcessCount > 0 {
        Divider()
          .padding(.vertical, 8)

        orphanedProcessesSection(viewModel: vm)
      }

      Divider()
        .padding(.vertical, 8)

      // Footer with refresh
      footerSection(onRefresh: { claudeService.refresh() }, lastUpdated: claudeService.lastUpdated)

      // Quit button at the bottom
      if showQuitButton {
        Divider()
          .padding(.vertical, 8)

        quitButton
      }
    } else {
      Text("Claude stats not available")
        .foregroundColor(.secondary)
        .padding()
    }
  }

  // MARK: - Codex Stats Content

  @ViewBuilder
  private var codexStatsContent: some View {
    if let codex = codexService, codex.isAvailable {
      // Header with optional loading indicator
      HStack {
        headerSection(title: "Codex Stats", icon: "chart.bar.fill", provider: .codex)
        if codex.isLoading {
          ProgressView()
            .scaleEffect(0.6)
            .frame(width: 16, height: 16)
        }
      }

      Divider()
        .padding(.vertical, 8)

      // Total stats
      codexTotalStatsSection(codex)

      Divider()
        .padding(.vertical, 8)

      // Model breakdown
      codexModelBreakdownSection(codex)

      Divider()
        .padding(.vertical, 8)

      // Footer with refresh
      footerSection(onRefresh: { codex.refresh() }, lastUpdated: codex.lastUpdated)

      // Quit button at the bottom
      if showQuitButton {
        Divider()
          .padding(.vertical, 8)

        quitButton
      }
    } else {
      Text("Codex stats not available")
        .foregroundColor(.secondary)
        .padding()
    }
  }

  // MARK: - Header Section

  private func headerSection(title: String, icon: String, provider: SessionProviderKind) -> some View {
    HStack {
      Image(systemName: icon)
        .foregroundColor(.brandPrimary(for: provider))
      Text(title)
        .font(.headline)
      Spacer()
    }
  }

  // MARK: - Claude Total Stats Section

  private var claudeTotalStatsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      StatRow(
        label: "Total Tokens",
        value: claudeService.formattedTotalTokens,
        icon: "number.circle.fill",
        provider: .claude
      )

      StatRow(
        label: "Estimated Cost",
        value: claudeService.formattedCost,
        icon: "dollarsign.circle.fill",
        provider: .claude
      )

      StatRow(
        label: "Sessions",
        value: "~\(claudeService.stats.totalSessions)",
        icon: "terminal.fill",
        provider: .claude
      )

      StatRow(
        label: "Messages",
        value: formatNumber(claudeService.stats.totalMessages),
        icon: "message.fill",
        provider: .claude
      )

      if claudeService.daysActive > 0 {
        StatRow(
          label: "Days Active",
          value: "\(claudeService.daysActive)",
          icon: "calendar",
          provider: .claude
        )
      }
    }
  }

  // MARK: - Codex Total Stats Section

  private func codexTotalStatsSection(_ codex: CodexGlobalStatsService) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      StatRow(
        label: "Total Tokens",
        value: codex.formattedTotalTokens,
        icon: "number.circle.fill",
        provider: .codex
      )

      StatRow(
        label: "Sessions",
        value: "\(codex.totalSessions)",
        icon: "terminal.fill",
        provider: .codex
      )

      StatRow(
        label: "Messages",
        value: formatNumber(codex.totalMessages),
        icon: "message.fill",
        provider: .codex
      )
    }
  }

  // MARK: - Claude Today Section

  private var claudeTodaySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Today")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)

      if let today = claudeService.todayActivity {
        HStack(spacing: 16) {
          MiniStat(value: "\(today.messageCount)", label: "msgs")
          MiniStat(value: "\(today.sessionCount)", label: "sessions")
          MiniStat(value: "\(today.toolCallCount)", label: "tools")
        }
      }
    }
  }

  // MARK: - Claude Model Breakdown Section

  private var claudeModelBreakdownSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("By Model")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)

      ForEach(claudeService.modelStats, id: \.name) { model in
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

  // MARK: - Codex Model Breakdown Section

  private func codexModelBreakdownSection(_ codex: CodexGlobalStatsService) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("By Model")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)

      ForEach(codex.sortedModelStats, id: \.name) { model in
        HStack {
          Text(model.name)
            .font(.caption)
          Spacer()
          Text(formatTokenCount(model.usage.totalTokens))
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      if codex.sortedModelStats.isEmpty {
        Text("No model data")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Orphaned Processes Section

  @ViewBuilder
  private func orphanedProcessesSection(viewModel: CLISessionsViewModel) -> some View {
    let count = viewModel.orphanedProcessCount

    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.orange)
          .frame(width: 16)
        Text("Orphaned Processes")
          .font(.caption)
        Spacer()
        Text("\(count)")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.orange)
      }

      Button(action: { viewModel.killOrphanedProcesses() }) {
        HStack {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.red)
          Text("Kill All")
            .font(.caption)
        }
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Footer Section

  private func footerSection(onRefresh: @escaping () -> Void, lastUpdated: Date?) -> some View {
    HStack {
      if let lastUpdated = lastUpdated {
        Text("Updated \(lastUpdated, style: .relative) ago")
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      Spacer()

      Button(action: onRefresh) {
        Image(systemName: "arrow.clockwise")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .help("Refresh stats")
    }
  }

  // MARK: - Quit Button

  private var quitButton: some View {
    Button("Quit app") {
      NSApplication.shared.terminate(nil)
    }
    .buttonStyle(.plain)
    .font(.caption)
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
  var provider: SessionProviderKind = .claude

  var body: some View {
    HStack {
      Image(systemName: icon)
        .foregroundColor(.brandPrimary(for: provider))
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
  GlobalStatsMenuView(claudeService: GlobalStatsService())
}
#endif
