//
//  MeasurementsSidePanelView.swift
//  AgentHub
//
//  Side panel listing the measurements an agent filed during a session.
//

import AgentHubCLIKit
import SwiftUI

/// Renders a session's measurement thread, newest measurement first.
///
/// Cards arrive from `agenthub_record_measurement` (see `MeasurementRecordMonitor`),
/// so this view only reads state — it never contacts an agent or a data source.
public struct MeasurementsSidePanelView: View {
  let session: CLISession
  let viewModel: CLISessionsViewModel
  let onDismiss: () -> Void
  var isEmbedded: Bool = false

  public init(
    session: CLISession,
    viewModel: CLISessionsViewModel,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false
  ) {
    self.session = session
    self.viewModel = viewModel
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
  }

  private var records: [MeasurementRecord] {
    viewModel.measurements(for: session)
  }

  public var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      if records.isEmpty {
        MeasurementEmptyState()
      } else {
        cardList
      }
    }
    .frame(
      minWidth: isEmbedded ? 320 : 620, idealWidth: isEmbedded ? .infinity : 760, maxWidth: .infinity,
      minHeight: isEmbedded ? 300 : 520, idealHeight: isEmbedded ? .infinity : 720, maxHeight: .infinity
    )
    .onKeyPress(.escape) {
      guard !isEmbedded else { return .handled }
      onDismiss()
      return .handled
    }
    .task(id: session.id) {
      viewModel.loadMeasurements(for: session)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label("Measurements", systemImage: "chart.bar.doc.horizontal")
        .font(.headline)

      if !records.isEmpty {
        Text("\(records.count)")
          .font(.caption2.monospacedDigit())
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.15))
          .clipShape(Capsule())
      }

      Spacer()

      Button("Close", action: onDismiss)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var cardList: some View {
    ScrollView {
      LazyVStack(spacing: 14) {
        ForEach(records) { record in
          MeasurementCardView(
            record: record,
            canRerun: viewModel.canRerunMeasurement(record, sessionId: session.id),
            isRerunning: viewModel.isRerunning(measurementId: record.id),
            onRerun: { viewModel.rerunMeasurement(id: record.id, in: session) }
          ) {
            viewModel.deleteMeasurement(id: record.id, in: session)
          }
        }
      }
      .padding(14)
    }
  }
}

/// Shown once every card has been removed. Names the tool explicitly so the
/// path back to a populated panel is obvious to someone who has never used it.
private struct MeasurementEmptyState: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "chart.bar.doc.horizontal")
        .font(.title2)
        .foregroundStyle(.secondary)

      Text("No measurements yet")
        .font(.callout.weight(.medium))

      Text("Ask this session to analyze something — query a database, aggregate a CSV, count events — and the result lands here as a chart with the query behind it.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 320)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}
