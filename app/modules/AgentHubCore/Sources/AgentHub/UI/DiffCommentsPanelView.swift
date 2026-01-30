//
//  DiffCommentsPanelView.swift
//  AgentHub
//
//  Created by Assistant on 1/29/26.
//

import SwiftUI

/// A collapsible panel showing all pending review comments.
///
/// Displays at the bottom of the diff viewer with a header showing count
/// and actions to send all comments to Claude or clear them.
struct DiffCommentsPanelView: View {

  // MARK: - Properties

  /// The shared state manager containing all pending review comments.
  @Bindable var commentsState: DiffCommentsState

  /// Called when the user taps "Send to Claude" to submit all comments as a batch.
  let onSendToCloud: () -> Void

  @State private var showClearConfirmation = false

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // Header bar (always visible when there are comments)
      headerBar

      // Content (shown when expanded)
      if commentsState.isPanelExpanded {
        Divider()

        ScrollView {
          let sortedFiles = commentsState.commentsByFile.keys.sorted()
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sortedFiles.enumerated()), id: \.element) { index, filePath in
              if let comments = commentsState.commentsByFile[filePath] {
                if index > 0 {
                  Divider()
                    .padding(.vertical, 4)
                }
                fileSection(filePath: filePath, comments: comments)
              }
            }
          }
          .padding(.vertical, 8)
        }
        .frame(maxHeight: 200)
      }
    }
    .background(Color.surfaceElevated)
    .overlay(
      Rectangle()
        .frame(height: 1)
        .foregroundColor(Color(NSColor.separatorColor)),
      alignment: .top
    )
    .confirmationDialog(
      "Clear All Comments",
      isPresented: $showClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear All", role: .destructive) {
        commentsState.clearAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will remove all \(commentsState.commentCount) pending comments. This action cannot be undone.")
    }
  }

  // MARK: - Header Bar

  private var headerBar: some View {
    HStack(spacing: 12) {
      // Expand/collapse button with count
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          commentsState.isPanelExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: commentsState.isPanelExpanded ? "chevron.down" : "chevron.up")
            .font(.caption.bold())

          Image(systemName: "text.bubble.fill")
            .font(.caption)

          Text("\(commentsState.commentCount) Comment\(commentsState.commentCount == 1 ? "" : "s")")
            .font(.caption.bold())
        }
        .foregroundColor(.primary)
      }
      .buttonStyle(.plain)

      Spacer()

      // Clear all button
      Button {
        showClearConfirmation = true
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "trash")
            .font(.caption)
          Text("Clear")
            .font(.caption)
        }
        .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Clear all comments")

      // Send to Claude button
      Button(action: onSendToCloud) {
        HStack(spacing: 4) {
          Image(systemName: "paperplane")
            .font(.caption)
          Text("Send \(commentsState.commentCount) to Claude")
            .font(.caption.bold())
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.primary.opacity(0.3), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .help("Send all comments to Claude (⌘⇧↵)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - File Section

  private func fileSection(filePath: String, comments: [DiffComment]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // File header
      HStack(spacing: 6) {
        Image(systemName: "doc.text.fill")
          .font(.caption)
          .foregroundColor(.primary)

        Text(URL(fileURLWithPath: filePath).lastPathComponent)
          .font(.system(.caption, design: .monospaced, weight: .semibold))
          .foregroundColor(.primary)

        Text("(\(comments.count))")
          .font(.caption2)
          .foregroundColor(.secondary)

        Spacer()
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 10)

      // Comments for this file with dividers
      ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
        if index > 0 {
          Divider()
            .padding(.leading, 10)
        }

        DiffCommentRow(
          comment: comment,
          onSave: { newText in
            commentsState.updateComment(id: comment.id, newText: newText)
          },
          onDelete: { commentsState.removeComment(id: comment.id) }
        )
      }
    }
  }
}

// MARK: - Preview

#Preview {
  struct PreviewWrapper: View {
    @State var commentsState = DiffCommentsState()

    var body: some View {
      VStack {
        Spacer()

        DiffCommentsPanelView(
          commentsState: commentsState,
          onSendToCloud: {}
        )
      }
      .frame(width: 800, height: 400)
      .onAppear {
        commentsState.addComment(
          filePath: "/path/to/Example.swift",
          lineNumber: 42,
          side: "right",
          lineContent: "let result = calculateValue()",
          text: "Consider adding error handling here"
        )
        commentsState.addComment(
          filePath: "/path/to/Example.swift",
          lineNumber: 58,
          side: "left",
          lineContent: "// TODO: refactor",
          text: "This should be addressed"
        )
        commentsState.addComment(
          filePath: "/path/to/Other.swift",
          lineNumber: 10,
          side: "right",
          lineContent: "func doSomething()",
          text: "Add documentation"
        )
        commentsState.isPanelExpanded = true
      }
    }
  }

  return PreviewWrapper()
}
