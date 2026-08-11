import AgentHubVoice
import SwiftUI

struct VoiceModeToggle: View {
  @Binding var mode: VoiceHUDMode
  var accentColor: Color?

  var body: some View {
    VoicePillSegmentedControl(
      selection: $mode,
      items: VoiceHUDMode.allCases.map { mode in
        VoicePillSegmentedControlItem(value: mode, title: mode.label)
      },
      selectedColor: accentColor,
      accessibilityLabel: "Voice mode"
    )
  }
}
