import AgentHubVoice
import SwiftUI

struct VoiceTranscriptList: View {
  let entries: [VoiceTranscriptEntry]

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        if entries.isEmpty {
          ContentUnavailableView(
            "Ready to listen",
            systemImage: "waveform",
            description: Text("Choose a target, then select the microphone.")
          )
          .frame(maxWidth: .infinity)
        } else {
          ForEach(entries.suffix(6)) { entry in
            VoiceTranscriptRow(entry: entry)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: 140, maxHeight: .infinity)
  }
}
