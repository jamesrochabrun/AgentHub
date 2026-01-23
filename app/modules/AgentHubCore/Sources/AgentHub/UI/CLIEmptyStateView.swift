//
//  CLIEmptyStateView.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import SwiftUI

// MARK: - CLIEmptyStateView

/// Empty state view prompting user to add a repository
public struct CLIEmptyStateView: View {
  let onAddRepository: () -> Void

  public init(onAddRepository: @escaping () -> Void) {
    self.onAddRepository = onAddRepository
  }

  public var body: some View {
    VStack {
      VStack(spacing: 20) {
        ZStack {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.brandPrimary.opacity(0.2),
                  Color.brandSecondary.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 72, height: 72)

          Image(systemName: "terminal")
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .foregroundColor(.brandPrimary)
        }

        VStack(spacing: 8) {
          Text("No Repositories Selected")
            .font(.system(.headline, design: .rounded))

          Text("Add a git repository to monitor CLI sessions from your terminal.")
            .font(.system(.caption, design: .rounded))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }

        Button(action: onAddRepository) {
          Label("Add Repository", systemImage: "plus.circle.fill")
            .font(.subheadline)
        }
        .buttonStyle(.borderedProminent)
        .tint(.brandPrimary)
      }
      .padding(24)
      .agentHubCard(isHighlighted: true)
      .frame(maxWidth: 360)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

// MARK: - Preview

#Preview {
  CLIEmptyStateView(onAddRepository: { })
    .frame(width: 400, height: 400)
}
