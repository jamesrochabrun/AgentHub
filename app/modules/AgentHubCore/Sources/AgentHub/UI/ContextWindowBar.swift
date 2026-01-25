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
  @State private var showingHelp = false

  private var barColor: Color {
    if percentage > 0.9 { return .red }
    if percentage > 0.75 { return .orange }
    return .brandPrimary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Context")
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.secondary)
        Spacer()
        if let model = model {
          ModelBadge(model: model)
        }
        Text(formattedUsage)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.secondary)

        // Help button
        Button {
          showingHelp.toggle()
        } label: {
          Image(systemName: "questionmark.circle")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingHelp) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Why is this an estimate?")
              .font(.subheadline)
              .fontWeight(.semibold)
            Text("Context usage is calculated from API response data (input + cache tokens). Claude Code's internal /context command includes additional overhead like autocompact buffer reservations that aren't exposed in session files.")
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(12)
          .frame(width: 280)
        }
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
