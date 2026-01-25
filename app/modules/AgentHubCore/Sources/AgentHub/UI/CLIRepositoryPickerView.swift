//
//  CLIRepositoryPickerView.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import SwiftUI

// MARK: - CLIRepositoryPickerView

/// Button to add a new repository with directory picker or GitHub clone
public struct CLIRepositoryPickerView: View {
  let onAddRepository: () -> Void
  var onCloneFromGitHub: (() -> Void)?

  @State private var showingGitHubPicker: Bool = false

  public init(
    onAddRepository: @escaping () -> Void,
    onCloneFromGitHub: (() -> Void)? = nil
  ) {
    self.onAddRepository = onAddRepository
    self.onCloneFromGitHub = onCloneFromGitHub
  }

  public var body: some View {
    HStack(spacing: 8) {
      // Add from local directory button (primary action)
      Button(action: onAddRepository) {
        Label("Add Repository", systemImage: "plus.circle")
      }
      .buttonStyle(.borderedProminent)
      .help("Select a local git repository to monitor CLI sessions")

      // Clone from GitHub button (secondary action)
      Button(action: {
        if let handler = onCloneFromGitHub {
          handler()
        } else {
          showingGitHubPicker = true
        }
      }) {
        Label("Clone from GitHub", systemImage: "network")
      }
      .buttonStyle(.bordered)
      .help("Clone a repository from GitHub")
    }
    .sheet(isPresented: $showingGitHubPicker) {
      GitHubRepositoryPickerView(
        onSelect: { repo in
          // Placeholder - will be wired to clone logic in PS3
          showingGitHubPicker = false
        },
        onDismiss: {
          showingGitHubPicker = false
        }
      )
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    CLIRepositoryPickerView(onAddRepository: { })

    CLIRepositoryPickerView(
      onAddRepository: { },
      onCloneFromGitHub: { print("Clone from GitHub") }
    )
  }
  .padding()
  .frame(width: 350)
}
