import Foundation
import SwiftUI

struct SimulatorRecordingAuditComposerView: View {
  @Binding var issue: String
  let onSend: () -> Void

  private var trimmedIssue: String {
    issue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSend: Bool {
    !trimmedIssue.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("What should the agent audit in this recording?", text: $issue, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(3...6)
        .padding(8)
        .background(
          Color(nsColor: .textBackgroundColor).opacity(0.82),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )

      HStack {
        Spacer()
        Button(action: onSend) {
          HStack(spacing: 6) {
            Image(systemName: "paperplane.fill")
            Text("Send")
            Text("⌘ Return")
              .font(.caption2.monospaced().weight(.semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(Color.brandPrimary)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityLabel("Send recording audit")
        .accessibilityHint("Sends with Command Return")
      }
    }
    .padding(10)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.16), radius: 10, y: 4)
  }
}
