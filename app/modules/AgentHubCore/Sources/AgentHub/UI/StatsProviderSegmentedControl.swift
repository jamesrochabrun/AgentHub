//
//  StatsProviderSegmentedControl.swift
//  AgentHub
//
//  Compact segmented control for switching between Claude and Codex stats.
//

import SwiftUI

/// A compact segmented control for the stats view with underline indicator
public struct StatsProviderSegmentedControl: View {
  @Binding var selectedProvider: SessionProviderKind
  let claudeSessionCount: Int
  let codexSessionCount: Int

  public init(
    selectedProvider: Binding<SessionProviderKind>,
    claudeSessionCount: Int = 0,
    codexSessionCount: Int = 0
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

      // Underline
      GeometryReader { geometry in
        let segmentWidth = geometry.size.width / 2
        Rectangle()
          .fill(Color.brandPrimary(for: selectedProvider))
          .frame(width: selectedProvider == .claude ? 80 : 100, height: 2)
          .offset(x: selectedProvider == .claude ? 0 : 96)
          .animation(.easeInOut(duration: 0.2), value: selectedProvider)
      }
      .frame(height: 2)
      .padding(.top, 6)
    }
  }

  private func segmentButton(for provider: SessionProviderKind, count: Int) -> some View {
    Button {
      selectedProvider = provider
    } label: {
      HStack(spacing: 6) {
        Text("\(provider.rawValue) (\(count))")
          .font(.system(.subheadline, weight: .medium))
          .foregroundColor(
            selectedProvider == provider
              ? Color.brandPrimary(for: provider)
              : .secondary
          )

        if provider == .codex {
          Text("Beta")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.2))
            .clipShape(Capsule())
        }
      }
    }
    .buttonStyle(.plain)
  }
}
