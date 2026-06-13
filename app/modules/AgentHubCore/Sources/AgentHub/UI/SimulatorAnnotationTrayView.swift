//
//  SimulatorAnnotationTrayView.swift
//  AgentHub
//
//  Floating, collapsible review card for simulator annotations. It mirrors the
//  diff comments panel pattern so queued annotations float above the live
//  simulator instead of resizing it.
//

import SimulatorPreview
import SwiftUI

struct SimulatorAnnotationTrayView: View {
  let annotations: [SimulatorAnnotation]
  let providerKind: SessionProviderKind
  let isSending: Bool
  @Binding var isExpanded: Bool

  let onRemove: (UUID) -> Void
  let onUpdateText: (UUID, String) -> Void
  let onSendAll: () -> Void
  let onClearAll: () -> Void

  @State private var showClearConfirmation = false
  @State private var isSendHovered = false

  private let morph = Animation.spring(response: 0.4, dampingFraction: 0.82)
  private let cardRadius: CGFloat = 16

  private var accent: Color { Color.brandPrimary(for: providerKind) }
  private var count: Int { annotations.count }
  private var countText: String { "\(count)" }
  private var commentsWord: String { count == 1 ? "Comment" : "Comments" }
  private var hasEmptyComment: Bool {
    annotations.contains {
      $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar

      if isExpanded {
        hairline
        annotationList
        hairline
        footerBar
      }
    }
    .frame(maxWidth: 460)
    .background(surfaceFill)
    .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 8)
    .animation(morph, value: isExpanded)
    .padding(.trailing, 16)
    .padding(.bottom, 14)
    .confirmationDialog(
      "Clear All Comments",
      isPresented: $showClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear All", role: .destructive, action: onClearAll)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will remove all \(count) pending simulator comments.")
    }
  }

  private var headerBar: some View {
    HStack(spacing: 10) {
      Button {
        toggleExpanded()
      } label: {
        HStack(spacing: 8) {
          countBadge
          Text("\(countText) \(commentsWord)")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Collapse simulator comments" : "Show simulator comments")

      sendButton

      Button {
        toggleExpanded()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 0 : 180))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Collapse" : "Expand")
    }
    .padding(.leading, 14)
    .padding(.trailing, 10)
    .padding(.vertical, 9)
  }

  @ViewBuilder
  private var sendButton: some View {
    Button(action: onSendAll) {
      HStack(spacing: 6) {
        if isSending {
          ProgressView()
            .controlSize(.mini)
          Text("Sending…")
        } else {
          Image(systemName: "paperplane.fill")
            .font(.system(size: 11, weight: .semibold))

          Text("Send")
            .font(.system(size: 12, weight: .semibold))
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(accent)
          .brightness(isSendHovered ? 0.06 : 0)
      )
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isSendHovered = $0 }
    .disabled(isSending || hasEmptyComment)
    .keyboardShortcut(.return, modifiers: .command)
    .help(hasEmptyComment ? "Add text to each comment before sending" : "Send simulator comments (⌘↵)")
  }

  private var annotationList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
          annotationRow(number: index + 1, annotation: annotation)
            .transition(.opacity)

          if annotation.id != annotations.last?.id {
            hairline
              .padding(.leading, 14)
          }
        }
      }
    }
    .frame(maxHeight: 300)
    .animation(.easeInOut(duration: 0.25), value: annotations.map(\.id))
  }

  private func annotationRow(number: Int, annotation: SimulatorAnnotation) -> some View {
    HStack(alignment: .top, spacing: 10) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(accent.opacity(0.9))
        .frame(width: 3)
        .frame(maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          SimulatorAnnotationPinBadge(number: number, size: 20)

          Text(annotationTargetLabel(for: annotation))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Spacer(minLength: 0)

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
          .help("Remove simulator comment")
        }

        if let target = annotation.target?.summary {
          Text(target)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            )
        }

        TextField("Comment", text: textBinding(for: annotation), axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .foregroundStyle(.primary.opacity(0.92))
          .lineLimit(1...3)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.primary.opacity(0.04))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
          )
          .disabled(isSending)
          .accessibilityLabel("Comment \(number)")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }

  private var footerBar: some View {
    HStack(spacing: 10) {
      Button {
        showClearConfirmation = true
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "trash")
            .font(.system(size: 11))
          Text("Clear all")
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSending)
      .help("Clear all simulator comments")

      Spacer(minLength: 0)

      Text("Click the simulator to add another")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var countBadge: some View {
    Text(countText)
      .font(.system(size: 11, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .frame(minWidth: 18)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(
        Capsule(style: .continuous)
          .fill(accent)
      )
  }

  private var hairline: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.08))
      .frame(height: 1)
  }

  private var surfaceFill: some View {
    ZStack {
      Color.surfaceElevated
      LinearGradient(
        colors: [Color.white.opacity(0.05), Color.clear],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  private func annotationTargetLabel(for annotation: SimulatorAnnotation) -> String {
    annotation.target?.summary ?? "Screen"
  }

  private func textBinding(for annotation: SimulatorAnnotation) -> Binding<String> {
    Binding(
      get: {
        annotations.first { $0.id == annotation.id }?.text ?? annotation.text
      },
      set: { newValue in
        onUpdateText(annotation.id, newValue)
      }
    )
  }

  private func toggleExpanded() {
    withAnimation(morph) {
      isExpanded.toggle()
    }
  }
}

#Preview {
  SimulatorAnnotationTrayView(
    annotations: [
      SimulatorAnnotation(
        normalizedX: 0.4,
        normalizedY: 0.3,
        text: "Move this title up a bit.",
        target: SimulatorAnnotationTarget(
          role: "Image",
          label: "unicorn",
          identifier: nil,
          frame: CGRect(x: 120, y: 80, width: 140, height: 160)
        )
      ),
      SimulatorAnnotation(
        normalizedX: 0.5,
        normalizedY: 0.6,
        text: "Make this primary action easier to read.",
        target: SimulatorAnnotationTarget(
          role: "Button",
          label: "Play",
          identifier: nil,
          frame: CGRect(x: 100, y: 320, width: 190, height: 44)
        )
      )
    ],
    providerKind: .claude,
    isSending: false,
    isExpanded: .constant(false),
    onRemove: { _ in },
    onUpdateText: { _, _ in },
    onSendAll: {},
    onClearAll: {}
  )
  .padding(24)
  .frame(width: 520, height: 240)
  .background(Color.black.opacity(0.8))
}
