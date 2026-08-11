import AgentHubVoice
import SwiftUI

struct VoiceTranscriptRow: View {
  let entry: VoiceTranscriptEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(roleLabel)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(entry.text)
        .font(.body)
        .foregroundStyle(entry.isPartial ? .secondary : .primary)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(9)
    .background(rowColor, in: RoundedRectangle(cornerRadius: 10))
  }

  private var roleLabel: String {
    switch entry.role {
    case .user:
      "You"
    case .assistant:
      "AgentHub"
    case .system:
      "Update"
    case .tool:
      "Tool"
    }
  }

  private var rowColor: Color {
    entry.role == .user ? .accentColor.opacity(0.12) : .secondary.opacity(0.08)
  }
}
