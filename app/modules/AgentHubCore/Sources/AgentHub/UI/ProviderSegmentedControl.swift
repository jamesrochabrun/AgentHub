//
//  ProviderSegmentedControl.swift
//  AgentHub
//
//  Custom segmented control for switching between Claude and Codex providers.
//  Always shows both tabs regardless of installation status.
//

import SwiftUI

public struct ProviderSegmentedControl: View {
  @Binding var selectedProvider: SessionProviderKind
  let claudeSessionCount: Int
  let codexSessionCount: Int

  public init(
    selectedProvider: Binding<SessionProviderKind>,
    claudeSessionCount: Int,
    codexSessionCount: Int,
    claudeEnabled: Bool = true,
    codexEnabled: Bool = true
  ) {
    self._selectedProvider = selectedProvider
    self.claudeSessionCount = claudeSessionCount
    self.codexSessionCount = codexSessionCount
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        segmentButton(for: .claude, count: claudeSessionCount)
        segmentButton(for: .codex, count: codexSessionCount)
        Spacer()
      }

      Rectangle()
        .fill(Color.brandPrimary(for: selectedProvider))
        .frame(height: 2)
    }
  }

  private func segmentButton(for provider: SessionProviderKind, count: Int) -> some View {
    Button {
      selectedProvider = provider
    } label: {
      HStack(spacing: 4) {
        Text(provider.rawValue)
          .font(.system(.subheadline, weight: .semibold))
        if count > 0 {
          Text("(\(count))")
            .font(.system(.subheadline, weight: .regular))
        }
      }
      .foregroundColor(selectedProvider == provider ? Color.brandPrimary(for: provider) : .secondary)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
