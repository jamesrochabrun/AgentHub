//
//  CLIRepositoryPickerView.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import SwiftUI

// MARK: - CLIRepositoryPickerView

/// Button to add a new repository with directory picker
public struct CLIRepositoryPickerView: View {
  let onAddRepository: () -> Void

  public init(onAddRepository: @escaping () -> Void) {
    self.onAddRepository = onAddRepository
  }

  public var body: some View {
    Button(action: onAddRepository) {
      HStack(spacing: 8) {
        Image(systemName: "plus.circle")
          .font(.system(size: DesignTokens.IconSize.md))
          .foregroundColor(.primary)

        Text("Add Repository")
          .font(.system(size: 13))
          .foregroundColor(.primary)

        Spacer()
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .fill(Color.secondary.opacity(0.2))
      )
      .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    }
    .buttonStyle(.plain)
    .help("Select a git repository to monitor CLI sessions")
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    CLIRepositoryPickerView(onAddRepository: { })
  }
  .padding()
  .frame(width: 350)
}
