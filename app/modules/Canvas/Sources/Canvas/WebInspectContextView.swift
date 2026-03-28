//
//  WebInspectContextView.swift
//  WebInspector
//
//  Lightweight read-only overlay shown in context mode after an element
//  is selected. Displays element info briefly before auto-dismissing.
//

import AppKit
import SwiftUI

/// Read-only element summary card shown in context mode.
///
/// Unlike ``WebInspectInputView``, this view has no text editor — the element
/// context is sent to the host app immediately on selection.
struct WebInspectContextView: View {

  let element: ElementInspectorData
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      // Tag badge
      Text(element.tagName.lowercased())
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.blue.opacity(0.8))
        )

      // Selector
      Text(element.cssSelector)
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      // Text preview (if any)
      if !element.textContent.isEmpty {
        Text("\"\(element.textContent)\"")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: 140)
      }

      // Dismiss button
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Exit context mode (Esc)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity)
    .background(Color(NSColor.controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: -4)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
  }
}
