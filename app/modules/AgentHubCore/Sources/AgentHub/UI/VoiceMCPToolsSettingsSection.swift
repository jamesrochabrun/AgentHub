import SwiftUI

struct VoiceMCPToolsSettingsSection: View {
  let servers: [VoiceMCPServerDescriptor]
  let isEnabled: (VoiceMCPServerDescriptor) -> Bool
  let onToggle: (VoiceMCPServerDescriptor, Bool) -> Void

  var body: some View {
    Section("MCP Tools") {
      if servers.isEmpty {
        Text("No MCP servers found in your Claude (~/.claude.json) or Codex (~/.codex/config.toml) configuration.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(servers) { server in
          VoiceMCPServerRow(
            server: server,
            isEnabled: isEnabled(server),
            onToggle: { onToggle(server, $0) }
          )
        }
        Text("Enabled servers run locally when a voice conversation needs them; tool results become part of the conversation sent to OpenAI.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct VoiceMCPServerRow: View {
  let server: VoiceMCPServerDescriptor
  let isEnabled: Bool
  let onToggle: (Bool) -> Void

  var body: some View {
    if server.isSupported {
      Toggle(isOn: Binding(get: { isEnabled }, set: onToggle)) {
        VStack(alignment: .leading, spacing: 2) {
          Text(server.name)
          Text(detailText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name)
          .foregroundStyle(.secondary)
        Text(server.unsupportedReason ?? "This server is not supported.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var detailText: String {
    let providers = server.providers
      .map { $0 == .claude ? "Claude" : "Codex" }
      .joined(separator: " · ")
    return "\(providers) — \(server.transportDescription)"
  }
}
