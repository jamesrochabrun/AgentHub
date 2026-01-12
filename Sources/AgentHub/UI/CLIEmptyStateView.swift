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
    VStack(spacing: 20) {
      Image(systemName: "terminal")
        .font(.system(size: 48))
        .foregroundColor(.secondary)

      VStack(spacing: 8) {
        Text("No Repositories Selected")
          .font(.headline)

        Text("Add a git repository to monitor CLI sessions from your terminal.")
          .font(.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }

      Button(action: onAddRepository) {
        Label("Add Repository", systemImage: "plus.circle.fill")
          .font(.subheadline)
      }
      .buttonStyle(.borderedProminent)
      .tint(.brandPrimary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

// MARK: - Preview

#Preview {
  CLIEmptyStateView(onAddRepository: { print("Add repository") })
    .frame(width: 400, height: 400)
}
