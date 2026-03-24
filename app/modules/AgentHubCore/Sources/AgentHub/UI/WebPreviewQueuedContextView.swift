//
//  WebPreviewQueuedContextView.swift
//  AgentHub
//
//  Created by Assistant on 3/23/26.
//

import AppKit
import Canvas
import SwiftUI

/// Passive queue panel shown below the preview while context-mode selections are pending.
struct WebPreviewQueuedContextView: View {
  let queuedElements: [ElementInspectorData]
  let isSelectingContext: Bool
  let onRemoveElement: (UUID) -> Void
  let onClearAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      queuedElementList
    }
    .frame(maxWidth: .infinity)
    .background(Color(NSColor.controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: -4)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
  }

  private var header: some View {
    HStack(spacing: 10) {
      Label("Queued Context", systemImage: "square.stack.3d.up")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)

      Text("\(queuedElements.count)")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(Color.secondary.opacity(0.15))
        )

      Text(
        isSelectingContext
          ? "Click more elements to attach them to the next terminal message."
          : "These selections will attach to the next terminal message you send."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)

      Spacer()

      Button("Clear") {
        onClearAll()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Clear queued context")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var queuedElementList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(queuedElements) { element in
          queuedElementRow(for: element)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
    .frame(maxHeight: min(CGFloat(max(queuedElements.count, 1)) * 70, 190))
  }

  private func queuedElementRow(for element: ElementInspectorData) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(element.tagName.lowercased())
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.85))
            )

          Text(element.cssSelector)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Text(elementPreviewText(for: element))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.tail)
      }

      Spacer(minLength: 8)

      Button {
        onRemoveElement(element.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Remove selection")
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(NSColor.windowBackgroundColor).opacity(0.65))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
  }

  private func elementPreviewText(for element: ElementInspectorData) -> String {
    if !element.outerHTML.isEmpty {
      return element.outerHTML
    }
    if !element.textContent.isEmpty {
      return "\"\(element.textContent)\""
    }
    return element.tagName.lowercased()
  }
}
