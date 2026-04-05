//
//  WebPreviewLaunchOptionsView.swift
//  AgentHub
//
//  Chooser presented before AgentHub starts its own managed preview for a
//  project with no live session localhost URL yet.
//

import SwiftUI

struct WebPreviewLaunchOptionsView: View {
  let launchOptions: WebPreviewLaunchOptions
  let statusMessage: String?
  let onAskAgent: () -> Void
  let onOpenStaticPreview: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Spacer()

      Image(systemName: "globe")
        .font(.system(size: 44))
        .foregroundColor(.secondary.opacity(0.7))

      Text("Choose Preview Source")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("No live localhost URL is available for this session yet. Ask the agent to launch localhost, or open a static fallback when one exists.")
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)

      VStack(spacing: 10) {
        if launchOptions.canAskAgent {
          Button("Ask Agent To Start Preview", action: onAskAgent)
            .buttonStyle(.borderedProminent)
        }

        if launchOptions.hasStaticFallback {
          Button("Open Static Preview", action: onOpenStaticPreview)
            .buttonStyle(.bordered)
        }
      }

      if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 40)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
