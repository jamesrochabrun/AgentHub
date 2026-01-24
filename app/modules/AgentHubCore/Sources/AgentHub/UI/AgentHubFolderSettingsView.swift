//
//  AgentHubFolderSettingsView.swift
//  AgentHub
//
//  Settings view for choosing AgentHub folder location
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - AgentHubFolderSettingsView

/// Settings view for configuring the AgentHub folder location
/// where cloned repositories are stored
public struct AgentHubFolderSettingsView: View {
  @State private var folderPath: String

  /// Default folder path (~/AgentHub)
  private static var defaultFolderPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("AgentHub")
      .path
  }

  public init() {
    let savedPath = UserDefaults.standard.string(forKey: AgentHubDefaults.agentHubFolderPath)
    _folderPath = State(initialValue: savedPath ?? Self.defaultFolderPath)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Header
      VStack(alignment: .leading, spacing: 4) {
        Text("AgentHub Folder")
          .font(.headline)

        Text("Cloned repositories from GitHub will be stored in this folder.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      // Folder path display and picker
      folderPathSection

      // Info note
      infoNote
    }
    .padding(16)
  }

  // MARK: - Folder Path Section

  private var folderPathSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Location")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      HStack(spacing: 12) {
        // Path display
        HStack(spacing: 8) {
          Image(systemName: "folder.fill")
            .font(.system(size: DesignTokens.IconSize.md))
            .foregroundColor(.brandPrimary)

          Text(folderPath)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
            .fill(Color.surfaceOverlay)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )

        // Choose button
        Button(action: showFolderPicker) {
          Text("Choose...")
        }
        .buttonStyle(.bordered)

        // Reset to default button
        if folderPath != Self.defaultFolderPath {
          Button(action: resetToDefault) {
            Image(systemName: "arrow.counterclockwise")
          }
          .buttonStyle(.bordered)
          .help("Reset to default location")
        }
      }
    }
  }

  // MARK: - Info Note

  private var infoNote: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "info.circle")
        .font(.system(size: DesignTokens.IconSize.sm))
        .foregroundColor(.blue)

      Text("The folder will be created if it doesn't exist when you clone a repository.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.blue.opacity(0.08))
    )
  }

  // MARK: - Actions

  private func showFolderPicker() {
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.title = "Choose AgentHub Folder"
    panel.message = "Select where cloned repositories should be stored"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true

    // Set initial directory to current folder or home
    if FileManager.default.fileExists(atPath: folderPath) {
      panel.directoryURL = URL(fileURLWithPath: folderPath)
    } else {
      panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    }

    if panel.runModal() == .OK, let url = panel.url {
      folderPath = url.path
      saveFolderPath()
    }
    #endif
  }

  private func resetToDefault() {
    folderPath = Self.defaultFolderPath
    saveFolderPath()
  }

  private func saveFolderPath() {
    UserDefaults.standard.set(folderPath, forKey: AgentHubDefaults.agentHubFolderPath)
  }
}

// MARK: - Preview

#Preview {
  AgentHubFolderSettingsView()
    .frame(width: 450)
    .padding()
}
