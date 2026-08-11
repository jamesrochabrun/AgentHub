import AgentHubVoice
import SwiftUI

struct VoiceTargetChip: View {
  let target: VoiceHUDTarget?
  let targets: [VoiceHUDTarget]
  let onSelect: (String?) -> Void

  var body: some View {
    Menu {
      Button("Automatic target") {
        onSelect(nil)
      }

      Divider()

      ForEach(targets) { candidate in
        Button {
          onSelect(candidate.id)
        } label: {
          Label(
            candidate.detail.map { "\(candidate.name) · \($0)" }
              ?? candidate.name,
            systemImage: candidate.id == target?.id ? "checkmark" : "terminal"
          )
        }
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "scope")
        Text(target?.name ?? "No session target")
          .lineLimit(1)
        Spacer()
        if let detail = target?.detail {
          Text(detail)
            .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.secondary.opacity(0.1), in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Voice session target")
  }
}
