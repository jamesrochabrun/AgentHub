import SwiftUI

struct TweakGenerationBanner: View {
  static let message = "Tweaks are being generated. This can take a few minutes."
  let startedAt: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(Self.message)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        ProgressView()
          .controlSize(.small)
          .accessibilityHidden(true)
      }

      TimelineView(.periodic(from: startedAt, by: 1)) { context in
        let elapsedTime = Self.elapsedTime(from: startedAt, to: context.date)
        Text(elapsedTime)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .accessibilityLabel("Elapsed time")
          .accessibilityValue(elapsedTime)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .combine)
  }

  static func elapsedTime(from startDate: Date, to currentDate: Date) -> String {
    let elapsedSeconds = max(0, Int(currentDate.timeIntervalSince(startDate)))
    let hours = elapsedSeconds / 3_600
    let minutes = (elapsedSeconds % 3_600) / 60
    let seconds = elapsedSeconds % 60

    if hours > 0 {
      return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
    }
    return "\(minutes):\(twoDigits(seconds))"
  }

  private static func twoDigits(_ value: Int) -> String {
    if value < 10 {
      return "0\(value)"
    }
    return "\(value)"
  }
}
