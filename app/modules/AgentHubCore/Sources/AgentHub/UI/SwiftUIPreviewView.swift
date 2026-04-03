//
//  SwiftUIPreviewView.swift
//  AgentHub
//
//  Side panel view for rendering SwiftUI #Preview blocks inline.
//

import AppKit
import SwiftUI
import SwiftUIPreviewKit

struct SwiftUIPreviewView: View {
  let session: CLISession
  let projectPath: String
  var onDismiss: (() -> Void)?
  var isEmbedded: Bool = false

  @State private var buildService: PreviewBuildService
  @State private var autoRefresh = false
  @Environment(\.colorScheme) private var colorScheme

  init(
    session: CLISession,
    projectPath: String,
    onDismiss: (() -> Void)? = nil,
    isEmbedded: Bool = false
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    _buildService = State(initialValue: PreviewBuildService(
      scanner: PreviewScanner(),
      hostGenerator: PreviewHostGenerator(),
      screenshotService: SimulatorScreenshotService()
    ))
  }

  var body: some View {
    VStack(spacing: 0) {
      SwiftUIPreviewHeaderView(
        buildState: buildService.buildState,
        selectedPreview: buildService.selectedPreview,
        previewCount: buildService.previews.count,
        autoRefresh: $autoRefresh,
        onDismiss: onDismiss
      )
      Divider()
      SwiftUIPreviewContentView(
        buildService: buildService,
        projectPath: projectPath,
        session: session
      )
    }
    .frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity, minHeight: 300)
    .task {
      buildService.onBuildUserProject = { projPath, udid in
        SimulatorService.derivedDataPath(for: projPath)
      }
      await buildService.scanPreviews(projectPath: projectPath, moduleName: nil)
    }
    .onKeyPress(.escape) {
      onDismiss?()
      return .handled
    }
  }
}

// MARK: - Header

private struct SwiftUIPreviewHeaderView: View {
  let buildState: PreviewBuildState
  let selectedPreview: PreviewDeclaration?
  let previewCount: Int
  @Binding var autoRefresh: Bool
  let onDismiss: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "eye")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let preview = selectedPreview {
        Text(preview.displayName)
          .font(.caption)
          .fontWeight(.medium)
          .lineLimit(1)
      } else {
        Text("SwiftUI Preview")
          .font(.caption)
          .fontWeight(.medium)
      }

      if let label = buildState.phaseLabel {
        Text(label)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if previewCount > 0 {
        Text("\(previewCount) preview\(previewCount == 1 ? "" : "s")")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      if let onDismiss {
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .help("Close preview panel")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

// MARK: - Content

private struct SwiftUIPreviewContentView: View {
  let buildService: PreviewBuildService
  let projectPath: String
  let session: CLISession

  var body: some View {
    switch buildService.buildState {
    case .idle, .scanningPreviews:
      if buildService.previews.isEmpty && buildService.buildState == .idle {
        emptyState
      } else if buildService.previews.isEmpty {
        ProgressView("Scanning for previews…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        PreviewPickerView(
          previews: buildService.previews,
          selected: buildService.selectedPreview,
          onSelect: { preview in
            let udid = SimulatorService.shared.preferredSimulatorUDIDs[projectPath] ?? ""
            Task {
              await buildService.buildPreview(preview, udid: udid, projectPath: projectPath)
            }
          }
        )
      }

    case .buildingUserProject, .generatingHost, .buildingHost, .installing, .capturing:
      VStack(spacing: 12) {
        ProgressView()
        if let label = buildService.buildState.phaseLabel {
          Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

    case .ready(let imagePath):
      previewImage(at: imagePath)

    case .failed(let error):
      failedState(error: error)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "eye.slash")
        .font(.title2)
        .foregroundStyle(.tertiary)
      Text("No #Preview blocks found")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("Add #Preview { ... } to your SwiftUI files")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func previewImage(at path: String) -> some View {
    if let nsImage = NSImage(contentsOfFile: path) {
      ScrollView {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity)
          .padding(12)
      }
      .background(Color.black.opacity(0.05))
    } else {
      Text("Failed to load preview image")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func failedState(error: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(.orange)
      Text("Preview Failed")
        .font(.caption)
        .fontWeight(.medium)
      ScrollView {
        Text(error)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
      .frame(maxHeight: 200)
      .background(Color(.textBackgroundColor).opacity(0.5))
      .cornerRadius(6)

      if let preview = buildService.selectedPreview {
        Button("Retry") {
          let udid = SimulatorService.shared.preferredSimulatorUDIDs[projectPath] ?? ""
          Task {
            await buildService.buildPreview(preview, udid: udid, projectPath: projectPath)
          }
        }
        .buttonStyle(.agentHubOutlined)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
