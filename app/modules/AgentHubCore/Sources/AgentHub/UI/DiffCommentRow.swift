//
//  DiffCommentRow.swift
//  AgentHub
//
//  Created by Assistant on 1/29/26.
//

import SwiftUI

/// A single review comment inside the floating comments card.
///
/// Each row shows a colored side accent (additions/deletions), the line
/// reference, a code-snippet preview, and the comment body. Edit and delete
/// controls fade in on hover to keep the resting state clean.
struct DiffCommentRow: View {

  // MARK: - Properties

  /// The diff comment to display in this row.
  let comment: DiffComment

  /// Provider whose brand color is used for emphasis.
  let providerKind: SessionProviderKind

  /// Called when the user saves an edited comment with new text.
  let onSave: (String) -> Void

  /// Called when the user taps the delete button.
  let onDelete: () -> Void

  @State private var isHovered = false
  @State private var isEditing = false
  @State private var editText: String = ""

  init(
    comment: DiffComment,
    providerKind: SessionProviderKind = .claude,
    onSave: @escaping (String) -> Void,
    onDelete: @escaping () -> Void
  ) {
    self.comment = comment
    self.providerKind = providerKind
    self.onSave = onSave
    self.onDelete = onDelete
  }

  // MARK: - Derived

  private var sideColor: Color {
    switch comment.side {
    case "left": return .red
    case "right": return .green
    default: return Color.brandPrimary(for: providerKind)
    }
  }

  private var sideLabel: String {
    switch comment.side {
    case "left": return "old"
    case "right": return "new"
    case "plan": return "plan"
    default: return comment.side
    }
  }

  // MARK: - Body

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Side accent bar (green = additions, red = deletions)
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(sideColor.opacity(0.9))
        .frame(width: 3)
        .frame(maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 6) {
        locationRow

        // Line content (code preview)
        Text(comment.lineContent)
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(comment.endLineNumber != nil ? 3 : 1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.primary.opacity(0.05))
          )

        // Comment text or edit field
        if isEditing {
          editingView
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
          Text(comment.text)
            .font(.system(size: 12))
            .foregroundColor(.primary.opacity(0.92))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .background(isEditing ? Color.primary.opacity(0.04) : Color.clear)
    .onHover { hovering in
      isHovered = hovering
    }
  }

  // MARK: - Location Row

  private var locationRow: some View {
    HStack(spacing: 6) {
      // Line number or range
      Text(comment.lineLabel)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundColor(.primary)

      // Side indicator pill
      Text(sideLabel)
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(sideColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          Capsule(style: .continuous)
            .fill(sideColor.opacity(0.15))
        )

      Spacer(minLength: 0)

      // Action buttons (always rendered to prevent layout shift, opacity controlled by hover)
      HStack(spacing: 4) {
        actionButton(
          systemName: "pencil",
          tint: .primary,
          help: "Edit comment"
        ) {
          editText = comment.text
          withAnimation(.easeOut(duration: 0.2)) {
            isEditing = true
          }
        }

        actionButton(
          systemName: "trash",
          tint: .red,
          help: "Delete comment",
          action: onDelete
        )
      }
      .opacity(isHovered && !isEditing ? 1 : 0)
      .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
  }

  private func actionButton(
    systemName: String,
    tint: Color,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(tint)
        .frame(width: 22, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: - Editing View

  private var editingView: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextEditor(text: $editText)
        .font(.system(size: 12))
        .scrollContentBackground(.hidden)
        .padding(4)
        .background(Color.primary.opacity(0.05))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(minHeight: 44, maxHeight: 90)

      HStack(spacing: 10) {
        Spacer()

        Button("Cancel") {
          withAnimation(.easeOut(duration: 0.2)) {
            isEditing = false
          }
          editText = ""
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundColor(.secondary)

        Button("Save") {
          onSave(editText)
          withAnimation(.easeOut(duration: 0.2)) {
            isEditing = false
          }
          editText = ""
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color.brandPrimary(for: providerKind))
        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 0) {
    DiffCommentRow(
      comment: DiffComment(
        filePath: "/path/to/Example.swift",
        lineNumber: 42,
        side: "right",
        lineContent: "let result = calculateValue()",
        text: "Consider adding error handling here for the case when calculation fails."
      ),
      onSave: { _ in },
      onDelete: {}
    )

    Divider()

    DiffCommentRow(
      comment: DiffComment(
        filePath: "/path/to/Example.swift",
        lineNumber: 58,
        side: "left",
        lineContent: "// TODO: refactor this later",
        text: "This should be addressed"
      ),
      onSave: { _ in },
      onDelete: {}
    )
  }
  .frame(width: 440)
  .background(Color.surfaceElevated)
}
