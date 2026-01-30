//
//  DiffCommentRow.swift
//  AgentHub
//
//  Created by Assistant on 1/29/26.
//

import SwiftUI

/// A row displaying a single diff comment with inline edit/delete actions.
/// Uses flat styling consistent with CLISessionRow.
struct DiffCommentRow: View {

  // MARK: - Properties

  /// The diff comment to display in this row.
  let comment: DiffComment

  /// Called when the user saves an edited comment with new text.
  let onSave: (String) -> Void

  /// Called when the user taps the delete button.
  let onDelete: () -> Void

  @State private var isHovered = false
  @State private var isEditing = false
  @State private var editText: String = ""

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Location header
      locationRow

      // Line content (code preview)
      Text(comment.lineContent)
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      // Comment text or edit field
      if isEditing {
        editingView
          .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
      } else {
        Text(comment.text)
          .font(.caption)
          .foregroundColor(.primary.opacity(0.9))
          .lineLimit(2)
          .transition(.opacity)
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .contentShape(Rectangle())
    .agentHubFlatRow(isHighlighted: isEditing)
    .onHover { hovering in
      isHovered = hovering
    }
  }

  // MARK: - Editing View

  private var editingView: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextEditor(text: $editText)
        .font(.callout)
        .scrollContentBackground(.hidden)
        .background(Color.primary.opacity(0.05))
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(minHeight: 40, maxHeight: 80)

      HStack(spacing: 8) {
        Spacer()

        Button("Cancel") {
          isEditing = false
          editText = ""
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundColor(.secondary)

        Button("Save") {
          onSave(editText)
          isEditing = false
          editText = ""
        }
        .buttonStyle(.plain)
        .font(.caption.bold())
        .foregroundColor(.brandPrimary)
        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.horizontal, 4)
    }
  }

  // MARK: - Location Row

  private var locationRow: some View {
    HStack(spacing: 6) {
      // Comment indicator
      Image(systemName: "text.bubble.fill")
        .font(.caption2)
        .foregroundColor(.primary)

      // Line number
      Text("Line \(comment.lineNumber)")
        .font(.system(.caption, design: .monospaced, weight: .semibold))
        .foregroundColor(.primary)

      // Side indicator
      Text("(\(comment.side == "left" ? "old" : "new"))")
        .font(.caption2)
        .foregroundColor(.secondary)

      Spacer()

      // Action buttons (always rendered to prevent layout shift, opacity controlled by hover)
      HStack(spacing: 6) {
        Button {
          editText = comment.text
          withAnimation(.easeOut(duration: 0.2)) {
            isEditing = true
          }
        } label: {
          Image(systemName: "pencil")
            .font(.caption2)
            .foregroundColor(.primary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .background(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Edit comment")

        Button(action: onDelete) {
          Image(systemName: "trash")
            .font(.caption2)
            .foregroundColor(.red)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .background(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Delete comment")
      }
      .opacity(isHovered && !isEditing ? 1 : 0)
      .animation(.easeInOut(duration: 0.15), value: isHovered)
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
  .frame(width: 350)
}
