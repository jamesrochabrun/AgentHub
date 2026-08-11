import AgentHubVoice
import SwiftUI

struct VoiceAPIKeySettingsSection: View {
  @Binding var apiKey: String
  let keySource: OpenAIKeySource?
  let saveMessage: String?
  let isSaving: Bool
  let onSave: () -> Void

  var body: some View {
    Section {
      SecureField("OpenAI API key", text: $apiKey)
        .textContentType(.password)

      HStack {
        if keySource == .environment {
          Label("Using OPENAI_API_KEY", systemImage: "terminal")
            .foregroundStyle(.secondary)
        } else if keySource == .keychain {
          Label("Stored in Keychain", systemImage: "key.fill")
            .foregroundStyle(.secondary)
        } else {
          Text("No API key configured")
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button("Save", action: onSave)
          .disabled(isSaving)
      }

      if let saveMessage {
        Text(saveMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("OpenAI")
    } footer: {
      Text("AgentHub uses this key only for dictation and realtime voice.")
    }
  }
}
