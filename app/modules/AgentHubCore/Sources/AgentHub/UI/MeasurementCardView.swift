//
//  MeasurementCardView.swift
//  AgentHub
//
//  One measurement: the claim, the numbers behind it, and the query that produced them.
//

import AgentHubCLIKit
import AppKit
import SwiftUI

struct MeasurementCardView: View {
  let record: MeasurementRecord
  var canRerun: Bool = false
  var isRerunning: Bool = false
  var onRerun: (() -> Void)? = nil
  let onDelete: () -> Void

  @State private var isQueryExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      MeasurementCardHeader(
        record: record,
        canRerun: canRerun,
        isRerunning: isRerunning,
        onRerun: onRerun,
        onDelete: onDelete
      )

      Text(record.claim)
        .font(.body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)

      if let chart = record.chart {
        MeasurementChartView(chart: chart)
      }

      if let table = record.table, !table.rows.isEmpty {
        MeasurementTableView(table: table)
      }

      if let history = record.history, !history.isEmpty {
        MeasurementHistoryView(record: record, history: history)
      }

      if !record.caveats.isEmpty {
        MeasurementCaveatsView(caveats: record.caveats)
      }

      if let query = record.query, !query.isEmpty {
        MeasurementQueryDisclosure(query: query, isExpanded: $isQueryExpanded)
      }

      if let source = record.source, !source.isEmpty {
        MeasurementSourceFooter(source: source)
      }
    }
    .padding(14)
    .background(Color(NSColor.textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
    )
  }
}

// MARK: - Header

private struct MeasurementCardHeader: View {
  let record: MeasurementRecord
  let canRerun: Bool
  let isRerunning: Bool
  let onRerun: (() -> Void)?
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(record.title)
          .font(.headline)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        if let question = record.question, !question.isEmpty {
          Text(question)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 8)

      if isRerunning {
        ProgressView()
          .controlSize(.mini)
      } else if canRerun {
        Button { onRerun?() } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Re-run this query and refresh the numbers")
        .accessibilityLabel("Re-run this measurement")
      }

      Text(timestampLabel)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize()

      Menu {
        Button("Copy Claim") {
          MeasurementPasteboard.copy(record.claim)
        }
        if let query = record.query, !query.isEmpty {
          Button("Copy Query") {
            MeasurementPasteboard.copy(query)
          }
        }
        Divider()
        Button("Remove Card", role: .destructive, action: onDelete)
      } label: {
        Image(systemName: "ellipsis")
          .font(.caption)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 20)
      .accessibilityLabel("Card actions")
    }
  }

  /// "updated" only appears once a card has actually been refreshed — saying it
  /// on a first-time measurement would imply a re-run that never happened.
  private var timestampLabel: String {
    let relative = record.displayDate.formatted(.relative(presentation: .numeric))
    if isRerunning {
      return "re-running…"
    }
    return record.hasBeenRerun ? "updated \(relative)" : relative
  }
}

// MARK: - Table

/// Renders the table with a `Grid` so columns size to their content.
///
/// Fixed-width columns truncated long file paths to `CLISessio…odel.swift`
/// while numeric columns wasted half their width; the grid gives every column
/// exactly what it needs and only scrolls when the total genuinely overflows.
private struct MeasurementTableView: View {
  let table: MeasurementTable

  var body: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
            cell(column, isHeader: true)
          }
        }

        Divider()
          .gridCellUnsizedAxes(.horizontal)

        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
          GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, value in
              cell(value, isHeader: false)
            }
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .frame(maxHeight: 220)
    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private func cell(_ value: String, isHeader: Bool) -> some View {
    Text(value)
      .font(.caption)
      .fontWeight(isHeader ? .semibold : .regular)
      .monospacedDigit()
      .foregroundStyle(isHeader ? .secondary : .primary)
      .lineLimit(1)
      .padding(.vertical, 3)
  }
}

// MARK: - History

/// Earlier runs of the same measurement.
///
/// This is what turns a card from a snapshot into a tracked metric: when the
/// measurement measures a single number, the runs plot as a trend; otherwise each
/// run is listed with what was claimed at the time, so a month-old reading is
/// still readable rather than silently overwritten.
private struct MeasurementHistoryView: View {
  let record: MeasurementRecord
  let history: [MeasurementRun]

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "chevron.right")
            .font(.caption2)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Text(history.count == 1 ? "1 earlier run" : "\(history.count) earlier runs")
            .font(.caption.weight(.medium))
          if let delta = deltaLabel {
            Text(delta)
              .font(.caption2.weight(.semibold))
          }
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      if isExpanded {
        if let trend {
          MeasurementChartView(chart: trend)
        }

        VStack(alignment: .leading, spacing: 6) {
          ForEach(record.runs.reversed()) { run in
            MeasurementHistoryRow(
              run: run,
              isCurrent: run.runAt == record.displayDate,
              showsBranch: showsBranch
            )
          }
        }
      }
    }
  }

  /// A trend across runs, split by branch — see `MeasurementTrendBuilder`.
  private var trend: MeasurementChart? {
    MeasurementTrendBuilder.chart(for: record.runs, title: record.title)
  }

  /// Naming the branch on every row is noise when they all ran on the same one.
  private var showsBranch: Bool {
    MeasurementTrendBuilder.spansMultipleBranches(record.runs)
  }

  /// Change against the previous run **on the same branch**. Comparing across
  /// branches would report a branch difference as movement over time.
  private var deltaLabel: String? {
    let previousOnSameBranch = history.last { $0.branchName == record.branchName }
    guard let current = record.scalarValue,
          let previous = previousOnSameBranch?.scalarValue,
          previous != 0
    else {
      return nil
    }
    let change = (current - previous) / abs(previous) * 100
    guard abs(change) >= 0.5 else { return "unchanged" }
    return String(format: "%@%.0f%%", change > 0 ? "+" : "", change)
  }

  // Deliberately no red/green on the delta. Whether a number going up is good
  // depends on the metric — down is good for build time and bad for weekly
  // actives — and AgentHub is not told which. Colouring it would confidently
  // mislead half the time; the sign alone is unambiguous.

}

private struct MeasurementHistoryRow: View {
  let run: MeasurementRun
  let isCurrent: Bool
  let showsBranch: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(run.runAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)

        if showsBranch, let branch = run.branchName {
          Text(branch)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .frame(width: 108, alignment: .leading)

      Text(run.claim)
        .font(.caption)
        .foregroundStyle(isCurrent ? .primary : .secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Caveats

/// Caveats get their own visually distinct block rather than small print.
/// The whole point of the panel is that a number arrives with the reasons it
/// might mislead attached to it, so they must survive a skim.
private struct MeasurementCaveatsView: View {
  let caveats: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Read with care", systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)

      ForEach(Array(caveats.enumerated()), id: \.offset) { _, caveat in
        HStack(alignment: .top, spacing: 6) {
          Text("•")
          Text(caveat)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(Color.orange.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

// MARK: - Query

private struct MeasurementQueryDisclosure: View {
  let query: String
  @Binding var isExpanded: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button {
          withAnimation(.easeInOut(duration: 0.15)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "chevron.right")
              .font(.caption2)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Text("Query")
              .font(.caption.weight(.medium))
          }
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)

        Spacer()

        if isExpanded {
          Button("Copy") {
            MeasurementPasteboard.copy(query)
          }
          .buttonStyle(.plain)
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }

      if isExpanded {
        ScrollView(.horizontal, showsIndicators: true) {
          Text(query)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
        }
        .frame(maxHeight: 160)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }
    }
  }
}

// MARK: - Source

private struct MeasurementSourceFooter: View {
  let source: String

  var body: some View {
    Label(source, systemImage: "cylinder.split.1x2")
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .truncationMode(.middle)
  }
}

// MARK: - Pasteboard

enum MeasurementPasteboard {
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
