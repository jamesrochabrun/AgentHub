//
//  CLINotInstalledView.swift
//  AgentHub
//
//  Shows "CLI Not Installed" state for a specific provider.
//

import SwiftUI

/// Empty state view shown when a CLI provider is not installed
public struct CLINotInstalledView: View {
  let provider: SessionProviderKind

  public init(provider: SessionProviderKind) {
    self.provider = provider
  }

  public var body: some View {
    VStack {
      VStack(spacing: 20) {
        ZStack {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color.brandPrimary(for: provider).opacity(0.2),
                  Color.brandPrimary(for: provider).opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 72, height: 72)

          Image(systemName: "terminal")
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .foregroundColor(Color.brandPrimary(for: provider))
        }

        VStack(spacing: 8) {
          Text("\(provider.rawValue) CLI Not Installed")
            .font(.system(.headline, design: .rounded))

          Text(installationMessage)
            .font(.system(.caption, design: .rounded))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }

        Link(destination: installationURL) {
          Label("Installation Guide", systemImage: "arrow.up.right.circle.fill")
            .font(.subheadline)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.brandPrimary(for: provider))
      }
      .padding(24)
      .agentHubCard(isHighlighted: true)
      .frame(maxWidth: 360)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var installationMessage: String {
    switch provider {
    case .claude:
      return "Install Claude CLI to monitor and manage your Claude Code sessions."
    case .codex:
      return "Install Codex CLI to monitor and manage your Codex sessions."
    }
  }

  private var installationURL: URL {
    switch provider {
    case .claude:
      return URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!
    case .codex:
      return URL(string: "https://github.com/openai/codex")!
    }
  }
}

#Preview("Claude Not Installed") {
  CLINotInstalledView(provider: .claude)
    .frame(width: 400, height: 400)
}

#Preview("Codex Not Installed") {
  CLINotInstalledView(provider: .codex)
    .frame(width: 400, height: 400)
}
