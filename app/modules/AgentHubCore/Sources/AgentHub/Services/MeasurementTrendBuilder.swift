import AgentHubCLIKit
import Foundation

/// Builds the "over time" chart shown under a measurement's history.
///
/// Splits by branch. Measurements roll up to the repository, so runs from
/// `main` and from a feature worktree land on the same card; plotted as one
/// series they interleave — 214, 163, 211, 160 — and a pair of perfectly stable
/// branches reads as a metric thrashing. One series per branch makes that the
/// comparison it actually is.
enum MeasurementTrendBuilder {
  /// A trend needs at least two runs, and every run has to measure the same
  /// single number — there is no meaningful "value over time" for a multi-series
  /// breakdown.
  static func chart(for runs: [MeasurementRun], title: String) -> MeasurementChart? {
    guard runs.count >= 2 else { return nil }

    let scalars = runs.compactMap { run -> (run: MeasurementRun, value: Double)? in
      guard let value = run.scalarValue else { return nil }
      return (run, value)
    }
    guard scalars.count == runs.count else { return nil }

    let grouped = Dictionary(grouping: scalars) { $0.run.branchName ?? title }
    // Stable order: whichever branch was measured first leads the legend.
    let branchOrder = scalars.reduce(into: [String]()) { order, entry in
      let key = entry.run.branchName ?? title
      if !order.contains(key) { order.append(key) }
    }

    let series = branchOrder.compactMap { branch -> MeasurementSeries? in
      guard let entries = grouped[branch] else { return nil }
      let points = entries.map {
        MeasurementPoint(x: label(for: $0.run.runAt), y: $0.value)
      }
      return MeasurementSeries(name: branch, points: points)
    }
    guard !series.isEmpty else { return nil }

    // Order the axis by when each run happened, across every branch — grouping
    // by series would put one branch's dates before the other's regardless of
    // chronology.
    let xOrder = scalars
      .sorted { $0.run.runAt < $1.run.runAt }
      .map { label(for: $0.run.runAt) }
      .reduce(into: [String]()) { order, label in
        if !order.contains(label) { order.append(label) }
      }

    return MeasurementChart(
      kind: .line,
      yLabel: "Over time",
      series: series,
      xOrder: xOrder
    )
  }

  /// Whether the runs span more than one branch, and so whether naming the
  /// branch on each history row is informative or just noise.
  static func spansMultipleBranches(_ runs: [MeasurementRun]) -> Bool {
    Set(runs.compactMap(\.branchName)).count > 1
  }

  static func label(for date: Date) -> String {
    dateFormatter.string(from: date)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM"
    return formatter
  }()
}
