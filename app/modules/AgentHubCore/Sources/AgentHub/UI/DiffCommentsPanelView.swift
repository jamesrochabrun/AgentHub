//
//  DiffCommentsPanelView.swift
//  AgentHub
//
//  Created by Assistant on 1/29/26.
//

import SwiftUI

/// A collapsible bottom toolbar showing the pending review comment count.
/// Starts collapsed as a header; tapping expands to reveal clear and send actions.
struct DiffCommentsPanelView: View {

  // MARK: - Properties

  @Bindable var commentsState: DiffCommentsState
  let providerKind: SessionProviderKind
  let onSendToCloud: () -> Void

  @State private var isExpanded = false
  @State private var showClearConfirmation = false

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // Collapsed header — always visible
      headerView

      // Expanded content — shown on tap
      if isExpanded {
        Divider()

        // Comment list
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(commentsState.orderedComments) { comment in
              DiffCommentRow(
                comment: comment,
                onSave: { newText in
                  commentsState.updateComment(id: comment.id, newText: newText)
                },
                onDelete: {
                  commentsState.removeComment(id: comment.id)
                }
              )
              Divider()
            }
          }
        }
        .frame(maxHeight: 200)

        toolbarView
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .background(Color.surfaceElevated)
    .overlay(
      Rectangle()
        .frame(height: 1)
        .foregroundColor(Color(NSColor.separatorColor)),
      alignment: .top
    )
    .animation(.easeInOut(duration: 0.2), value: isExpanded)
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

  // MARK: - Header

  private var headerView: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundColor(.secondary)
          .frame(width: 10)

        Image(systemName: "text.bubble.fill")
          .font(.caption)
          .foregroundColor(.secondary)

        Text("\(commentsState.commentCount) Comment\(commentsState.commentCount == 1 ? "" : "s")")
          .font(.caption.bold())
          .foregroundColor(.primary)

        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Toolbar

  private var toolbarView: some View {
    HStack(spacing: 12) {
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

      // Send to provider button
      Button(action: onSendToCloud) {
        HStack(spacing: 4) {
          Image(systemName: "paperplane")
            .font(.caption)
          Text("Send \(commentsState.commentCount) to \(providerKind.rawValue)")
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
      .help("Send all comments to \(providerKind.rawValue) (⌘⇧↵)")
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
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
          providerKind: .claude,
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
      }
    }
  }

  return PreviewWrapper()
}
