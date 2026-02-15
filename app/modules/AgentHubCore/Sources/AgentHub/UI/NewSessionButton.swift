//
//  NewSessionButton.swift
//  AgentHub
//
//  Prominent button trigger for the New Session command palette
//

import SwiftUI

// MARK: - NewSessionButton

public struct NewSessionButton: View {
  @Bindable var viewModel: MultiSessionLaunchViewModel
  let intelligenceViewModel: IntelligenceViewModel?

  @State private var showingCommandPalette = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  public init(viewModel: MultiSessionLaunchViewModel, intelligenceViewModel: IntelligenceViewModel? = nil) {
    self.viewModel = viewModel
    self.intelligenceViewModel = intelligenceViewModel
  }

  public var body: some View {
    Button(action: {
      showingCommandPalette = true
    }) {
      HStack(spacing: 12) {
        // Icon
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.white)

        // Label
        VStack(alignment: .leading, spacing: 2) {
          Text("New Session")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)

          Text("Start Claude or Codex")
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.8))
        }

        Spacer()

        // Keyboard shortcut hint
        HStack(spacing: 4) {
          Text("⌘")
          Text("N")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white.opacity(0.7))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.white.opacity(0.2))
        )
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(
            LinearGradient(
              colors: [
                Color.brandPrimary(from: runtimeTheme),
                Color.brandPrimary(from: runtimeTheme).opacity(0.85)
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      )
      .shadow(color: Color.brandPrimary(from: runtimeTheme).opacity(0.3), radius: 8, y: 4)
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(
            LinearGradient(
              colors: [
                Color.white.opacity(0.2),
                Color.white.opacity(0.05)
              ],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .help("Open New Session command palette (⌘N)")
    .keyboardShortcut("n", modifiers: .command)
    .sheet(isPresented: $showingCommandPalette) {
      NewSessionCommandPalette(
        viewModel: viewModel,
        intelligenceViewModel: intelligenceViewModel,
        onDismiss: {
          showingCommandPalette = false
        }
      )
    }
  }
}

// MARK: - Preview

#Preview {
  let claudeViewModel = CLISessionsViewModel(
    monitorService: CLISessionMonitorService(),
    fileWatcher: SessionFileWatcher(),
    searchService: GlobalSearchService(),
    cliConfiguration: .claudeDefault,
    providerKind: .claude
  )
  let codexViewModel = CLISessionsViewModel(
    monitorService: CodexSessionMonitorService(),
    fileWatcher: CodexSessionFileWatcher(),
    searchService: CodexSearchService(),
    cliConfiguration: .codexDefault,
    providerKind: .codex
  )

  let launchViewModel = MultiSessionLaunchViewModel(
    claudeViewModel: claudeViewModel,
    codexViewModel: codexViewModel,
    intelligenceViewModel: nil
  )

  return NewSessionButton(
    viewModel: launchViewModel,
    intelligenceViewModel: nil
  )
  .padding()
  .frame(width: 350)
}
