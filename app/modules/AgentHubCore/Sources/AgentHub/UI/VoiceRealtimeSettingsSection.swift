import AgentHubVoicePanel
import SwiftUI

struct VoiceRealtimeSettingsSection: View {
  @Binding var realtimeModel: String
  @Binding var voiceName: String
  @Binding var vadEagerness: String
  @Binding var dictationModel: String
  @Binding var language: String

  private static let languages: [(code: String, name: String)] = [
    ("auto", "Automatic"),
    ("en", "English"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("zh", "Chinese"),
    ("hi", "Hindi"),
  ]

  var body: some View {
    Section("Models and voice") {
      TextField("Realtime model", text: $realtimeModel)

      Picker("Voice", selection: $voiceName) {
        ForEach(VoiceOption.all) { option in
          Text("\(option.title) — \(option.tagline)").tag(option.id)
        }
      }

      Picker("Language", selection: $language) {
        ForEach(Self.languages, id: \.code) { language in
          Text(language.name).tag(language.code)
        }
      }
      Text("Pinning a language keeps replies consistent when background audio confuses transcription.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Conversation responsiveness", selection: $vadEagerness) {
        Text("Low").tag("low")
        Text("Medium").tag("medium")
        Text("High").tag("high")
        Text("Automatic").tag("auto")
      }

      TextField("Dictation model", text: $dictationModel)
    }
  }
}
