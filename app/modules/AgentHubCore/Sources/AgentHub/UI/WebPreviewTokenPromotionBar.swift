//
//  WebPreviewTokenPromotionBar.swift
//  AgentHub
//
//  Floating pill offered right after a style edit detached from a shared
//  design token: promote the edit into a token-wide update (rewriting the
//  token's definition) or dismiss to keep the element-scoped literal.
//

import SwiftUI

struct WebPreviewTokenPromotionBar: View {
  let offer: WebPreviewTokenPromotionOffer
  let onPromote: () -> Void
  let onDismiss: () -> Void

  init(
    offer: WebPreviewTokenPromotionOffer,
    onPromote: @escaping () -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.offer = offer
    self.onPromote = onPromote
    self.onDismiss = onDismiss
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "circle.hexagongrid")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      Text(offer.contextLabel)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)

      Button(action: onPromote) {
        Text(offer.actionLabel)
          .font(.system(size: 11, weight: .semibold))
      }
      .controlSize(.small)
      .help("Rewrite \(offer.token)'s definition so every element using it updates")

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Keep the change scoped to this element")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    .contentShape(Capsule())
  }
}
