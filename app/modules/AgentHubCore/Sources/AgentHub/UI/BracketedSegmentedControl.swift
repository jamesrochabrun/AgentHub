//
//  BracketedSegmentedControl.swift
//  AgentHub
//

import SwiftUI

public struct BracketedSegmentedControlItem<Value: Hashable>: Identifiable {
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

public struct BracketedSegmentedControl<Value: Hashable>: View {
  @Binding var selection: Value
  let items: [BracketedSegmentedControlItem<Value>]
  let selectedColor: Color
  let textColor: Color

  public init(
    selection: Binding<Value>,
    items: [BracketedSegmentedControlItem<Value>],
    selectedColor: Color,
    textColor: Color = .secondary
  ) {
    self._selection = selection
    self.items = items
    self.selectedColor = selectedColor
    self.textColor = textColor
  }

  public var body: some View {
    HStack(spacing: 8) {
      chrome("[")

      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        button(for: item)

        if index < items.count - 1 {
          chrome("|")
        }
      }

      chrome("]")
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private func button(for item: BracketedSegmentedControlItem<Value>) -> some View {
    Button {
      selection = item.value
    } label: {
      Text(item.title)
        .font(.secondaryCaption)
        .foregroundStyle(selection == item.value ? selectedColor : textColor)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(item.helpText ?? item.title)
  }

  private func chrome(_ value: String) -> some View {
    Text(value)
      .font(.secondaryCaption)
      .foregroundStyle(textColor)
      .accessibilityHidden(true)
  }
}
