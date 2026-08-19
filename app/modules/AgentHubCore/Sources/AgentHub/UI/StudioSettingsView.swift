//
//  StudioSettingsView.swift
//  AgentHub
//
//  Settings tab for reviewing and deleting stored Studio artifacts.
//

import AgentHubCLIKit
import SwiftUI

public struct StudioSettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var viewModel: StudioSettingsViewModel?
  @State private var expandedProjectKeys: Set<String> = []
  @State private var projectPendingDeletion: StudioLibrary.ProjectSummary?

  @AppStorage(AgentHubDefaults.studioAgentGuidanceEnabled)
  private var studioAgentGuidanceEnabled: Bool = true

  public init() {}

  public var body: some View {
    Form {
      Section {
        Toggle("Nudge agents toward Studio", isOn: $studioAgentGuidanceEnabled)
      } footer: {
        Text("Adds a short system-prompt note to new Claude and Codex sessions so \"show me three versions of this button\" renders on the Studio canvas instead of editing files or publishing elsewhere. The /agenthub-studio skill remains available either way. Applies to sessions launched after the change.")
      }

      if let viewModel {
        if viewModel.isEmpty, !viewModel.isLoading {
          Section {
            ContentUnavailableView(
              "No Studio Artifacts",
              systemImage: "paintpalette",
              description: Text("Artifacts and design canvases agents render with agenthub_artifact and agenthub_design are stored here, per project, and served only on this Mac.")
            )
          }
        } else {
          Section {
            ForEach(viewModel.projects) { project in
              StudioProjectRow(
                project: project,
                isExpanded: expandedProjectKeys.contains(project.projectKey),
                onToggle: { toggle(project) },
                onDeleteProject: { projectPendingDeletion = project },
                onDeleteArtifact: { id in
                  Task { await viewModel.delete(id: id, inProjectKey: project.projectKey) }
                }
              )
            }
          } header: {
            Text("Stored artifacts")
          } footer: {
            Text("\(viewModel.totalCount) artifact(s), \(ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file)) on disk. Nothing here is ever written into a project; delete freely.")
          }
        }
      }
    }
    .formStyle(.grouped)
    .task {
      if viewModel == nil {
        viewModel = StudioSettingsViewModel(library: agentHub?.studioLibrary)
      }
      await viewModel?.load()
    }
    .confirmationDialog(
      "Delete Studio artifacts?",
      isPresented: Binding(
        get: { projectPendingDeletion != nil },
        set: { if !$0 { projectPendingDeletion = nil } }
      ),
      presenting: projectPendingDeletion
    ) { project in
      Button("Delete \(project.artifacts.count)", role: .destructive) {
        let key = project.projectKey
        projectPendingDeletion = nil
        Task { await viewModel?.deleteAll(inProjectKey: key) }
      }
      Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
    } message: { project in
      Text("This removes \(project.artifacts.count) artifact(s) from \(StudioSettingsViewModel.displayName(forProjectKey: project.projectKey)) and frees \(ByteCountFormatter.string(fromByteCount: project.bytesOnDisk, countStyle: .file)). The agent can file them again.")
    }
  }

  private func toggle(_ project: StudioLibrary.ProjectSummary) {
    if expandedProjectKeys.contains(project.projectKey) {
      expandedProjectKeys.remove(project.projectKey)
    } else {
      expandedProjectKeys.insert(project.projectKey)
    }
  }
}

// MARK: - Rows

private struct StudioProjectRow: View {
  let project: StudioLibrary.ProjectSummary
  let isExpanded: Bool
  let onToggle: () -> Void
  let onDeleteProject: () -> Void
  let onDeleteArtifact: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button(action: onToggle) {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.caption2)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
            VStack(alignment: .leading, spacing: 2) {
              Text(StudioSettingsViewModel.displayName(forProjectKey: project.projectKey))
                .font(.body)
              Text(project.projectKey)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
        }
        .buttonStyle(.plain)

        Spacer()

        Text("\(project.artifacts.count) · \(ByteCountFormatter.string(fromByteCount: project.bytesOnDisk, countStyle: .file))")
          .font(.caption)
          .foregroundStyle(.secondary)

        Button(role: .destructive, action: onDeleteProject) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Delete every artifact for this project")
      }

      if isExpanded {
        ForEach(project.artifacts) { artifact in
          HStack(spacing: 8) {
            Image(systemName: artifact.kind == .canvas ? "square.grid.2x2" : "doc.richtext")
              .foregroundStyle(.secondary)
              .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
              Text(artifact.title)
                .font(.callout)
              Text(detail(for: artifact))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
              onDeleteArtifact(artifact.id)
            } label: {
              Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Delete this artifact")
          }
          .padding(.leading, 18)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func detail(for artifact: StudioArtifact) -> String {
    var parts: [String] = []
    parts.append(artifact.kind == .canvas ? "\(artifact.variants.count) variant(s)" : "document")
    parts.append("rev \(artifact.revision)")
    parts.append(artifact.displayDate.formatted(date: .abbreviated, time: .shortened))
    return parts.joined(separator: " · ")
  }
}
