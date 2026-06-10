//
//  SimulatorAnnotationTrayView.swift
//  AgentHub
//
//  Queued-feedback tray for simulator annotations — same interaction model as
//  the web preview's queued updates panel: review the pins, then send them to
//  the agent in one message (with a pin-stamped screenshot attached).
//

import AppKit
import SimulatorPreview
import SwiftUI

struct SimulatorAnnotationTrayView: View {
  let annotations: [SimulatorAnnotation]
  let isSending: Bool
  let onRemove: (UUID) -> Void
  let onSendAll: () -> Void
  let onClearAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      annotationList
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
      Label("Annotations", systemImage: "pin")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)

      Text("\(annotations.count)")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(Color.secondary.opacity(0.15))
        )

      Text("Sent to the agent with a pin-stamped screenshot.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer()

      sendButton

      Button("Clear") {
        onClearAll()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .disabled(isSending)
      .help("Discard all annotations")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var sendButton: some View {
    Button(action: onSendAll) {
      HStack(spacing: 5) {
        if isSending {
          ProgressView()
            .controlSize(.mini)
          Text("Sending…")
        } else {
          Text("Send")
          Text("⌘ ↩")
            .font(.system(.caption, design: .monospaced))
        }
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    .disabled(isSending)
    .keyboardShortcut(.return, modifiers: .command)
    .help("Send annotations to the agent (Command-Return)")
  }

  private var annotationList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
          annotationRow(number: index + 1, annotation: annotation)
            .transition(.opacity)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .frame(maxHeight: min(CGFloat(max(annotations.count, 1)) * 56, 200))
    .animation(.easeInOut(duration: 0.25), value: annotations.map(\.id))
  }

  private func annotationRow(number: Int, annotation: SimulatorAnnotation) -> some View {
    HStack(alignment: .center, spacing: 8) {
      SimulatorAnnotationPinBadge(number: number, size: 18)

      VStack(alignment: .leading, spacing: 2) {
        if let target = annotation.target {
          Text(target.summary)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Text(annotation.text)
          .font(.caption)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .truncationMode(.tail)
      }

      Spacer(minLength: 4)

      Button {
        onRemove(annotation.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSending)
      .help("Remove annotation")
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.windowBackgroundColor).opacity(0.65))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
  }
}
