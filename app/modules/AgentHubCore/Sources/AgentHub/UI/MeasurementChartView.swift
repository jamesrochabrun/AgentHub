//
//  MeasurementChartView.swift
//  AgentHub
//
//  Draws an agent-supplied chart specification with Swift Charts.
//

import AgentHubCLIKit
import Charts
import SwiftUI

/// Renders an `MeasurementChart`.
///
/// The agent sends values only; every visual decision is made here so cards stay
/// on the app's theme and no agent-authored markup reaches the panel.
struct MeasurementChartView: View {
  let chart: MeasurementChart

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // The y unit reads as a caption above the plot rather than a rotated axis
      // title. In a ~440pt side panel a vertical title crowds the plot area and
      // collides with the tick labels for no readability gain.
      if let yLabel = chart.yLabel, !yLabel.isEmpty {
        Text(yLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      plot
    }
  }

  private var plot: some View {
    Chart {
      ForEach(chart.series) { series in
        ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
          mark(for: point, seriesName: series.name)
        }
      }
    }
    .chartLegend(chart.series.count > 1 ? .visible : .hidden)
    .chartXAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(orientation: labelOrientation) {
          if let label = value.as(String.self) {
            Text(label)
              .font(.caption2)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(MeasurementNumberFormat.axis(number))
              .font(.caption2)
          }
        }
      }
    }
    .chartXScale(domain: chart.xOrder ?? derivedCategoryOrder)
    .chartXAxisLabel(position: .bottom, alignment: .center) {
      if let xLabel = chart.xLabel, !xLabel.isEmpty {
        Text(xLabel).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(height: 200)
  }

  @ChartContentBuilder
  private func mark(for point: MeasurementPoint, seriesName: String) -> some ChartContent {
    switch chart.kind {
    case .bar:
      BarMark(
        x: .value(chart.xLabel ?? "Category", point.x),
        y: .value(chart.yLabel ?? "Value", point.y)
      )
      .foregroundStyle(by: .value("Series", seriesName))
      .position(by: .value("Series", seriesName))
    case .line:
      LineMark(
        x: .value(chart.xLabel ?? "Category", point.x),
        y: .value(chart.yLabel ?? "Value", point.y)
      )
      .foregroundStyle(by: .value("Series", seriesName))
      .symbol(by: .value("Series", seriesName))
    case .area:
      AreaMark(
        x: .value(chart.xLabel ?? "Category", point.x),
        y: .value(chart.yLabel ?? "Value", point.y)
      )
      .foregroundStyle(by: .value("Series", seriesName))
      .opacity(0.7)
    case .point:
      PointMark(
        x: .value(chart.xLabel ?? "Category", point.x),
        y: .value(chart.yLabel ?? "Value", point.y)
      )
      .foregroundStyle(by: .value("Series", seriesName))
    }
  }

  /// Categories in order of first appearance — the same order Swift Charts
  /// would derive on its own, stated explicitly so the scale is always set.
  private var derivedCategoryOrder: [String] {
    chart.series
      .flatMap { $0.points.map(\.x) }
      .reduce(into: [String]()) { order, category in
        if !order.contains(category) { order.append(category) }
      }
  }

  private var labelOrientation: AxisValueLabelOrientation {
    switch MeasurementAxisLabelLayout.orientation(
      forCategories: chart.series.flatMap { $0.points.map(\.x) }
    ) {
    case .horizontal: .horizontal
    case .rotated: .verticalReversed
    }
  }
}

/// Decides whether category labels have to rotate.
///
/// Keyed on how much text has to fit, not how many points there are: seven
/// "Mon"/"Tue" labels sit comfortably side by side, while four file names do
/// not. Counting points alone rotated the days-of-week case for no reason.
enum MeasurementAxisLabelLayout {
  /// Framework-independent so the rule can be tested directly — Swift Charts'
  /// own `AxisValueLabelOrientation` is not `Equatable`.
  enum Orientation: Equatable {
    case horizontal
    case rotated
  }

  /// Rough usable plot width in the side panel, minus the y-axis gutter.
  static let assumedPlotWidth = 360.0
  /// Rough width of one character at `.caption2`, plus per-label breathing room.
  static let approximateCharacterWidth = 5.5
  static let perLabelPadding = 8.0

  static func orientation(forCategories categories: [String]) -> Orientation {
    // Series share an x axis, so the same category appearing in several series
    // is still one column.
    let distinct = Set(categories)
    guard !distinct.isEmpty else { return .horizontal }

    let widestLabel = distinct.map(\.count).max() ?? 0
    let requiredWidth =
      Double(distinct.count) * (Double(widestLabel) * approximateCharacterWidth + perLabelPadding)

    return requiredWidth > assumedPlotWidth ? .rotated : .horizontal
  }
}

/// Number formatting shared by the chart axis and the table.
enum MeasurementNumberFormat {
  /// Compact form for axis ticks: 12.5K, 3.2M.
  static func axis(_ value: Double) -> String {
    let magnitude = abs(value)
    switch magnitude {
    case 1_000_000_000...:
      return trimmed(value / 1_000_000_000) + "B"
    case 1_000_000...:
      return trimmed(value / 1_000_000) + "M"
    case 1_000...:
      return trimmed(value / 1_000) + "K"
    default:
      return trimmed(value)
    }
  }

  private static func trimmed(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(format: "%.1f", value)
  }
}
