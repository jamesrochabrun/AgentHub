import AgentHubCLIKit
import Foundation

enum SimulatorRecordingPromptBuilder {
  static func prompt(
    for recording: SimulatorRecordingResult,
    deviceName: String?,
    issue: String
  ) -> String {
    let trimmedIssue = issue.trimmingCharacters(in: .whitespacesAndNewlines)

    guard recording.isUsable else {
      var lines = [
        "The simulator recording could not be audited because AgentHub did not produce a finalized MP4:",
        recording.outputPath,
      ]

      if !trimmedIssue.isEmpty {
        lines.append(contentsOf: [
          "",
          "User issue:",
          trimmedIssue,
        ])
      }

      lines.append(contentsOf: [
        "",
        recording.validationError ?? "Recording did not finalize. Try recording again.",
      ])

      return lines.joined(separator: "\n")
    }

    var lines = [
      "Review this simulator recording and address the user's issue:",
      trimmedIssue.isEmpty ? "No issue was provided." : trimmedIssue,
      "",
      "Recording:",
      recording.outputPath,
      "",
      "Use ffprobe or ffmpeg to inspect timing and sampled frames as needed before changing code.",
    ]

    if let deviceName, !deviceName.isEmpty {
      lines.append("Device: \(deviceName)")
    }

    if recording.duration > 0 {
      let duration = recording.duration.formatted(.number.precision(.fractionLength(1)))
      lines.append("Duration: \(duration) seconds")
    }

    return lines.joined(separator: "\n")
  }
}
