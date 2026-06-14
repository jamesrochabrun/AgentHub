//
//  CompactPillSegmentedControl.swift
//  AgentHub
//

import SwiftUI

public struct CompactPillSegmentedControlItem<Value: Hashable>: Identifiable {
  public let value: Value
  public let title: String
  public let helpText: String?

  public var id: AnyHashable {
    AnyHashable(value)
  }

  public init(
    value: Value,
    title: String,
    helpText: String? = nil
  ) {
    self.value = value
    self.title = title
    self.helpText = helpText
  }
}

public struct CompactPillSegmentedControl<Value: Hashable>: View {
  private static var controlHeight: CGFloat { 26 }
  private static var selectedPillVerticalInset: CGFloat { 2 }

  @Binding private var selection: Value
  private let items: [CompactPillSegmentedControlItem<Value>]
  private let selectedColor: Color
  private let textColor: Color
  private let accessibilityLabel: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Namespace private var selectionNamespace

  public init(
    selection: Binding<Value>,
    items: [CompactPillSegmentedControlItem<Value>],
    selectedColor: Color = .brandSecondary,
    textColor: Color = .secondary,
    accessibilityLabel: String = "Segmented control"
  ) {
    self._selection = selection
    self.items = items
    self.selectedColor = selectedColor
    self.textColor = textColor
    self.accessibilityLabel = accessibilityLabel
  }

  public var body: some View {
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

  private func segmentButton(for item: CompactPillSegmentedControlItem<Value>) -> some View {
    let isSelected = selection == item.value

    return Button {
      withAnimation(selectionAnimation) {
        selection = item.value
      }
    } label: {
      Text(item.title)
        .font(.secondaryCaption)
        .lineLimit(1)
        .foregroundStyle(isSelected ? Color.white : textColor)
        .padding(.horizontal, 14)
        .frame(height: Self.controlHeight - (Self.selectedPillVerticalInset * 2))
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(selectedColor)
              .matchedGeometryEffect(id: "selected-pill", in: selectionNamespace)
              .shadow(color: selectedColor.opacity(0.18), radius: 6, y: 1)
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
