//
//  IconSegmentedControl.swift
//  AgentHub
//

import SwiftUI

public struct IconSegmentedControlItem<Value: Hashable>: Identifiable {
  public let value: Value
  public let systemImage: String
  public let helpText: String?

  public var id: AnyHashable {
    AnyHashable(value)
  }

  public init(
    value: Value,
    systemImage: String,
    helpText: String? = nil
  ) {
    self.value = value
    self.systemImage = systemImage
    self.helpText = helpText
  }
}

public struct IconSegmentedControl<Value: Hashable>: View {
  @Binding var selection: Value
  let items: [IconSegmentedControlItem<Value>]

  public init(
    selection: Binding<Value>,
    items: [IconSegmentedControlItem<Value>]
  ) {
    self._selection = selection
    self.items = items
  }

  public var body: some View {
    HStack(spacing: 6) {
      ForEach(items) { item in
        Button {
          selection = item.value
        } label: {
          Image(systemName: item.systemImage)
            .font(.caption)
            .foregroundStyle(selection == item.value ? .primary : .secondary)
            .frame(width: 26, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.helpText ?? "")
      }
    }
    .padding(4)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
