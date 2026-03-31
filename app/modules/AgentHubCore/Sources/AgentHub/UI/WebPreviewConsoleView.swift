//
//  WebPreviewConsoleView.swift
//  AgentHub
//
//  Displays captured console output from the inspected web view.
//

import SwiftUI

struct WebPreviewConsoleView: View {
  let entries: [String]
  let onClear: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Console")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Clear", action: onClear)
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .semibold))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color.surfaceElevated.opacity(0.75))

      if entries.isEmpty {
        ContentUnavailableView(
          "No Console Output",
          systemImage: "terminal",
          description: Text("Console logs, warnings, and errors from the preview will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { pair in
              let entry = pair.element
              Text(entry)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                  RoundedRectangle(cornerRadius: 8)
                    .fill(Color.surfaceElevated)
                )
            }
          }
          .padding(12)
        }
      }
    }
  }
}
