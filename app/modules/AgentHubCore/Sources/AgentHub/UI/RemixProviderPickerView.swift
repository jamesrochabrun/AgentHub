//
//  RemixProviderPickerView.swift
//  AgentHub
//

import SwiftUI

// MARK: - RemixProviderPickerView

struct RemixProviderPickerView: View {
  let session: CLISession
  let viewModel: CLISessionsViewModel?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 20) {
      Text("Remix in...")
        .font(.headline)

      HStack(spacing: 16) {
        providerButton(label: "Claude", systemImage: "c.circle") {
          dismiss()
          viewModel?.remixSession(session, targetProvider: .claude)
        }
        providerButton(label: "Codex", systemImage: "c.square") {
          dismiss()
          viewModel?.remixSession(session, targetProvider: .codex)
        }
      }

      Button("Cancel") { dismiss() }
        .foregroundStyle(.secondary)
    }
    .padding(24)
  }

  private func providerButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 28))
        Text(label)
          .font(.subheadline)
      }
      .frame(width: 90, height: 70)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }
}
