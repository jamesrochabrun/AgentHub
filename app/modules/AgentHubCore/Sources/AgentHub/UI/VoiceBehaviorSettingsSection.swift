import SwiftUI

struct VoiceBehaviorSettingsSection: View {
  @Binding var voiceEnabled: Bool
  @Binding var autoSubmitDictation: Bool
  @Binding var screenCaptureEnabled: Bool
  @Binding var allowBargeIn: Bool
  let registrationError: String?
  let onShowOnboarding: () -> Void

  var body: some View {
    Section("Behavior") {
      Toggle("Enable global shortcut (\(GlobalHotKey.voiceHUDDefault.displayString))", isOn: $voiceEnabled)

      Toggle("Automatically submit dictation", isOn: $autoSubmitDictation)

      Toggle(isOn: $screenCaptureEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Use Screenshots")
          Text("Let voice conversations capture a display or region for coding sessions")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Toggle(isOn: $allowBargeIn) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Allow interrupting the assistant")
          Text("Keeps the mic live while the assistant speaks. Without headphones, speaker echo can cut replies short — leave this off on open speakers.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Button("Show voice tour…", action: onShowOnboarding)

      if let registrationError {
        Label(registrationError, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    }
  }
}
