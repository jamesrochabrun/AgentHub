import SwiftUI

struct VoicePillSegmentedControlItem<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  let helpText: String?

  var id: AnyHashable {
    AnyHashable(value)
  }

  init(value: Value, title: String, helpText: String? = nil) {
    self.value = value
    self.title = title
    self.helpText = helpText
  }
}

/// The panel-module twin of the app's `CompactPillSegmentedControl` (this
/// module cannot import it): same track, pill, metrics, and spring selection
/// animation, with the selected color injected via `VoiceHUDConfiguration`.
struct VoicePillSegmentedControl<Value: Hashable>: View {
  private static var controlHeight: CGFloat { 26 }
  private static var selectedPillVerticalInset: CGFloat { 2 }

  @Binding var selection: Value
  let items: [VoicePillSegmentedControlItem<Value>]
  var selectedColor: Color?
  var accessibilityLabel = "Segmented control"

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Namespace private var selectionNamespace

  var body: some View {
    HStack(spacing: 2) {
      ForEach(items) { item in
        segmentButton(for: item)
      }
    }
    .padding(2)
    .frame(height: Self.controlHeight)
    .background(controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(controlBorder, lineWidth: 1)
    }
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private func segmentButton(
    for item: VoicePillSegmentedControlItem<Value>
  ) -> some View {
    let isSelected = selection == item.value
    let pillColor = selectedColor ?? Color.accentColor

    return Button {
      withAnimation(selectionAnimation) {
        selection = item.value
      }
    } label: {
      Text(item.title)
        .font(.system(size: 10))
        .lineLimit(1)
        .foregroundStyle(isSelected ? Color.white : Color.secondary)
        .padding(.horizontal, 14)
        .frame(height: Self.controlHeight - (Self.selectedPillVerticalInset * 2))
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(pillColor)
              .matchedGeometryEffect(id: "selected-pill", in: selectionNamespace)
              .shadow(color: pillColor.opacity(0.18), radius: 6, y: 1)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(item.helpText ?? item.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var selectionAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
  }

  private var controlFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
  }

  private var controlBorder: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.12)
  }
}
