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
      HStack {
        Image(systemName: "plus.circle.fill")
          .font(.title3)
          .foregroundColor(.brandPrimary)

        Text("Add Repository")
          .font(.subheadline)
          .fontWeight(.medium)

        Spacer()

        Image(systemName: "folder.badge.plus")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(Color.gray.opacity(0.1))
      .cornerRadius(8)
    }
    .buttonStyle(.plain)
    .help("Select a git repository to monitor CLI sessions")
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    CLIRepositoryPickerView(onAddRepository: { print("Add repository") })
  }
  .padding()
  .frame(width: 350)
}
