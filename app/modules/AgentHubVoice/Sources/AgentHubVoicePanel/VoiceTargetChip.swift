import AgentHubVoice
import SwiftUI

struct VoiceTargetChip: View {
  let target: VoiceHUDTarget?
  let targets: [VoiceHUDTarget]
  let isAssistantMode: Bool
  let onSelect: (String?) -> Void
  let onSelectAssistant: () -> Void

  var body: some View {
    Menu {
      Button {
        onSelectAssistant()
      } label: {
        Label(
          "Assistant · no session",
          systemImage: isAssistantMode ? "checkmark" : "sparkles"
        )
      }

      Divider()

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
        Image(systemName: isAssistantMode ? "sparkles" : "scope")
        Text(chipTitle)
          .lineLimit(1)
        Spacer()
        if let chipDetail {
          Text(chipDetail)
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

  private var chipTitle: String {
    if isAssistantMode { return "Assistant" }
    return target?.name ?? "No session target"
  }

  private var chipDetail: String? {
    if isAssistantMode { return "no session" }
    return target?.detail
  }
}
