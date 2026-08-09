//
//  MeasurementsSettingsView.swift
//  AgentHub
//
//  Settings tab for reviewing and deleting stored measurements.
//

import AgentHubCLIKit
import SwiftUI

/// Lists stored measurements by project and deletes them.
///
/// Grouped by project, never by worktree — see `MeasurementsSettingsViewModel`.
public struct MeasurementsSettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var viewModel: MeasurementsSettingsViewModel?
  @State private var expandedProjectPaths: Set<String> = []
  @State private var projectPendingDeletion: MeasurementProjectGroup?

  public init() {}

  public var body: some View {
    Form {
      if let viewModel {
        if viewModel.isEmpty, !viewModel.isLoading {
          Section {
            MeasurementsSettingsEmptyState()
          }
        } else {
          Section("Stored measurements") {
            ForEach(viewModel.groups) { group in
              MeasurementProjectRow(
                group: group,
                isExpanded: expandedProjectPaths.contains(group.projectPath),
                onToggle: { toggle(group) },
                onDeleteProject: { projectPendingDeletion = group },
                onDeleteMeasurement: { id in
                  Task { await viewModel.deleteMeasurement(id: id) }
                }
              )
            }
          }

          if viewModel.unscopedCount > 0 {
            Section("Unreachable") {
              MeasurementsUnscopedRow(count: viewModel.unscopedCount) {
                Task { await viewModel.sweepUnscoped() }
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task {
      if viewModel == nil {
        viewModel = MeasurementsSettingsViewModel(store: agentHub?.metadataStore)
      }
      await viewModel?.load()
    }
    .confirmationDialog(
      "Delete measurements?",
      isPresented: Binding(
        get: { projectPendingDeletion != nil },
        set: { if !$0 { projectPendingDeletion = nil } }
      ),
      presenting: projectPendingDeletion
    ) { group in
      Button("Delete \(group.measurements.count)", role: .destructive) {
        let path = group.projectPath
        projectPendingDeletion = nil
        Task { await viewModel?.deleteAll(inProjectPath: path) }
      }
      Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
    } message: { group in
      // Deleting takes the history with it, which is the part that cannot be
      // recovered by re-running — say so before they confirm.
      Text("This removes \(group.measurements.count) measurement(s) from \(group.displayName), including \(group.runCount) recorded run(s). Re-running later starts a fresh history.")
    }
  }

  private func toggle(_ group: MeasurementProjectGroup) {
    if expandedProjectPaths.contains(group.projectPath) {
      expandedProjectPaths.remove(group.projectPath)
    } else {
      expandedProjectPaths.insert(group.projectPath)
    }
  }
}

// MARK: - Project row

private struct MeasurementProjectRow: View {
  let group: MeasurementProjectGroup
  let isExpanded: Bool
  let onToggle: () -> Void
  let onDeleteProject: () -> Void
  let onDeleteMeasurement: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button(action: onToggle) {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.caption2)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))

            VStack(alignment: .leading, spacing: 2) {
              Text(group.displayName)
                .font(.body)
              Text(group.projectPath)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
        }
        .buttonStyle(.plain)

        Spacer(minLength: 8)

        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize()

        Button("Delete All", role: .destructive, action: onDeleteProject)
          .buttonStyle(.link)
      }

      if isExpanded {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(group.measurements) { measurement in
            MeasurementSettingsRow(measurement: measurement) {
              onDeleteMeasurement(measurement.id)
            }
          }
        }
        .padding(.leading, 18)
      }
    }
    .padding(.vertical, 2)
  }

  private var subtitle: String {
    let count = group.measurements.count
    let noun = count == 1 ? "measurement" : "measurements"
    guard let last = group.lastActivityAt else { return "\(count) \(noun)" }
    return "\(count) \(noun) · \(last.formatted(.relative(presentation: .numeric)))"
  }
}

// MARK: - Measurement row

private struct MeasurementSettingsRow: View {
  let measurement: MeasurementRecord
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(measurement.title)
          .font(.caption)
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 8)

      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Delete \(measurement.title)")
    }
    .padding(.vertical, 1)
  }

  private var detail: String {
    let runs = measurement.runs.count
    let runLabel = runs == 1 ? "1 run" : "\(runs) runs"
    let when = measurement.displayDate.formatted(.relative(presentation: .numeric))
    guard let branch = measurement.branchName else { return "\(runLabel) · \(when)" }
    return "\(runLabel) · \(branch) · \(when)"
  }
}

// MARK: - Unscoped

private struct MeasurementsUnscopedRow: View {
  let count: Int
  let onSweep: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(count == 1 ? "1 measurement with no project" : "\(count) measurements with no project")
          .font(.body)
        Text("These were recorded before AgentHub could resolve their project, so no panel can show them.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Button("Remove", role: .destructive, action: onSweep)
        .buttonStyle(.link)
    }
  }
}

// MARK: - Empty state

private struct MeasurementsSettingsEmptyState: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No measurements recorded")
        .font(.body)
      Text("When a session analyzes something — a git aggregation, a test-timing run, a query — it records the result here and in that project's Measurements panel.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
  }
}
