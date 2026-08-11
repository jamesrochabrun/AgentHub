import SwiftUI

struct VoiceModeToggle: View {
  @Binding var mode: VoiceHUDMode

  var body: some View {
    Picker("Voice mode", selection: $mode) {
      ForEach(VoiceHUDMode.allCases, id: \.self) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .pickerStyle(.segmented)
  }
}
