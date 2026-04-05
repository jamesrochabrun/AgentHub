//
//  WebPreviewDisconnectedBanner.swift
//  AgentHub
//
//  Banner shown when a live external preview disconnects after content already
//  loaded once.
//

import SwiftUI

struct WebPreviewDisconnectedBanner: View {
  let state: WebPreviewDisconnectedState
  let canUseManagedPreview: Bool
  let canAskAgent: Bool
  let statusMessage: String?
  let onRetry: () -> Void
  let onUseManagedPreview: () -> Void
  let onUseStaticPreview: () -> Void
  let onAskAgent: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(.orange)

        VStack(alignment: .leading, spacing: 4) {
          Text("Live Preview Disconnected")
            .font(.subheadline.weight(.semibold))

          Text("Showing the last successful render from \(state.url.absoluteString).")
            .font(.caption)
            .foregroundColor(.secondary)

          Text(state.error)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(2)
        }

        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Button("Retry", action: onRetry)
          .buttonStyle(.borderedProminent)

        if canUseManagedPreview {
          Button("Use App Preview", action: onUseManagedPreview)
            .buttonStyle(.bordered)
        }

        if state.hasStaticFallback {
          Button("Use Static Preview", action: onUseStaticPreview)
            .buttonStyle(.bordered)
        }

        if canAskAgent {
          Button("Ask Agent", action: onAskAgent)
            .buttonStyle(.bordered)
        }
      }

      if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.surfaceElevated)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
  }
}
