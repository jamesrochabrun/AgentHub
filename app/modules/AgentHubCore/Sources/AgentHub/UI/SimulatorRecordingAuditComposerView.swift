import Foundation
import SwiftUI

struct SimulatorRecordingAuditComposerView: View {
  @Binding var issue: String
  let onSend: () -> Void

  @State private var isSendHovered = false

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
              .font(.system(size: 11, weight: .semibold))
            Text("Send")
              .font(.system(size: 12, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(Color.brandPrimary)
              .brightness(isSendHovered ? 0.06 : 0)
          )
          .opacity(canSend ? 1 : 0.5)
          .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isSendHovered = $0 }
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(canSend ? "Send recording to the agent (⌘↵)" : "Describe what the agent should audit before sending")
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
