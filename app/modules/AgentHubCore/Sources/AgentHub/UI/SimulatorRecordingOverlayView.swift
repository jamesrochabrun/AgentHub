import AgentHubCLIKit
import SwiftUI

enum SimulatorRecordingPanelState: Equatable {
  case idle
  case starting
  case recording(SimulatorRecordingStarted)
  case stopping(SimulatorRecordingStarted)
  case sent(outputPath: String)
  case failed(String)

  var activeRecording: SimulatorRecordingStarted? {
    switch self {
    case .recording(let recording), .stopping(let recording):
      return recording
    case .idle, .starting, .sent, .failed:
      return nil
    }
  }

  var isBusy: Bool {
    switch self {
    case .starting, .stopping:
      return true
    case .idle, .recording, .sent, .failed:
      return false
    }
  }

  var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }
}

struct SimulatorRecordingOverlayView: View {
  let state: SimulatorRecordingPanelState
  let lastRecording: SimulatorRecordingResult?
  @Binding var auditIssue: String
  let canSendToAgent: Bool
  let onSendToAgent: (SimulatorRecordingResult, String) -> Void
  let onReveal: (SimulatorRecordingResult) -> Void
  let onDiscard: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    Group {
      switch state {
      case .starting:
        recordingPill(title: "Starting recording", detail: nil, showsProgress: true)

      case .recording(let recording):
        recordingPill(
          title: "Recording simulator",
          detail: recording.outputPath,
          showsProgress: false,
          trailing: {
            Button(action: onDiscard) {
              Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Stop and delete recording")
            .accessibilityLabel("Stop and delete recording")
          }
        )

      case .stopping:
        recordingPill(title: "Finishing recording", detail: nil, showsProgress: true)

      case .sent(let outputPath):
        recordingPill(
          title: "Sent to agent",
          detail: outputPath,
          indicator: .success
        ) {
          EmptyView()
        }

      case .failed(let message):
        recordingPill(
          title: "Recording failed",
          detail: message,
          showsProgress: false,
          trailing: {
            Button(action: onDismiss) {
              Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Dismiss recording error")
          }
        )

      case .idle:
        if let lastRecording {
          savedRecordingPill(lastRecording)
        }
      }
    }
    .frame(maxWidth: 520, alignment: .leading)
  }

  private func savedRecordingPill(_ recording: SimulatorRecordingResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      recordingPill(
        title: recording.isUsable ? "Recording saved" : "Recording unavailable",
        detail: recording.isUsable ? recording.outputPath : recording.validationError,
        showsProgress: false,
        trailing: {
          if recording.fileExists {
            Button(action: { onReveal(recording) }) {
              Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reveal recording in Finder")
            .accessibilityLabel("Reveal recording in Finder")
          }

          Button(action: onDiscard) {
            Image(systemName: "xmark")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .help("Delete recording")
          .accessibilityLabel("Delete recording")
        }
      )

      if canSendToAgent, recording.isUsable {
        SimulatorRecordingAuditComposerView(
          issue: $auditIssue,
          onSend: { onSendToAgent(recording, auditIssue) }
        )
      }
    }
  }

  private enum PillIndicator {
    case progress
    case recordingDot
    case success
  }

  private func recordingPill<Trailing: View>(
    title: String,
    detail: String?,
    indicator: PillIndicator,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 10) {
      switch indicator {
      case .progress:
        ProgressView()
          .controlSize(.small)
      case .recordingDot:
        Circle()
          .fill(Color.red)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
      case .success:
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
        if let detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      trailing()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
  }

  private func recordingPill<Trailing: View>(
    title: String,
    detail: String?,
    showsProgress: Bool,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    recordingPill(
      title: title,
      detail: detail,
      indicator: showsProgress ? .progress : .recordingDot,
      trailing: trailing
    )
  }

  private func recordingPill(
    title: String,
    detail: String?,
    showsProgress: Bool
  ) -> some View {
    recordingPill(title: title, detail: detail, showsProgress: showsProgress) {
      EmptyView()
    }
  }
}
