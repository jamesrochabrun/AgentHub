//
//  ContextWindowBar.swift
//  AgentHub
//
//  Created by Assistant on 1/18/26.
//

import SwiftUI

// MARK: - ContextWindowBar

/// Visual bar showing context window usage percentage
struct ContextWindowBar: View {
  let percentage: Double
  let formattedUsage: String
  var model: String? = nil

  private var barColor: Color {
    if percentage > 0.9 { return .red }
    if percentage > 0.75 { return .orange }
    return .brandPrimary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Context")
          .font(.caption2)
          .foregroundColor(.secondary)
        Spacer()
        if let model = model {
          ModelBadge(model: model)
        }
        Text(formattedUsage)
          .font(.caption2)
          .monospacedDigit()
      }

      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.gray.opacity(0.2))
          RoundedRectangle(cornerRadius: 2)
            .fill(barColor)
            .frame(width: geometry.size.width * min(percentage, 1.0))
        }
      }
      .frame(height: 4)
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 20) {
    ContextWindowBar(
      percentage: 0.07,
      formattedUsage: "~15K / 200K (~7%)",
      model: "claude-opus-4-20250514"
    )

    ContextWindowBar(
      percentage: 0.45,
      formattedUsage: "~90K / 200K (~45%)",
      model: "claude-sonnet-4-20250514"
    )

    ContextWindowBar(
      percentage: 0.78,
      formattedUsage: "~156K / 200K (~78%)",
      model: "claude-haiku-4-20250514"
    )

    ContextWindowBar(
      percentage: 0.95,
      formattedUsage: "~190K / 200K (~95%)"
    )
  }
  .padding()
  .frame(width: 300)
}
