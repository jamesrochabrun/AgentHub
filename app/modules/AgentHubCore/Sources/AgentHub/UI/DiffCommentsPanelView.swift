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
  let isSendShortcutEnabled: Bool
  let onSendToCloud: () -> Void

  @State private var isExpanded = false
  @State private var showClearConfirmation = false

  init(
    commentsState: DiffCommentsState,
    providerKind: SessionProviderKind,
    isSendShortcutEnabled: Bool = true,
    onSendToCloud: @escaping () -> Void
  ) {
    self.commentsState = commentsState
    self.providerKind = providerKind
    self.isSendShortcutEnabled = isSendShortcutEnabled
    self.onSendToCloud = onSendToCloud
  }

  // MARK: - Body

  var body: some View {
    headerView
      .background(Color.surfaceElevated)
      .overlay(alignment: .top) {
        expandedTray
      }
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

  @ViewBuilder
  private var expandedTray: some View {
    if isExpanded {
      VStack(spacing: 0) {
        expandedContent
        Divider()
      }
      .frame(maxWidth: .infinity)
      .background(Color.surfaceElevated)
      .overlay(
        Rectangle()
          .frame(height: 1)
          .foregroundColor(Color(NSColor.separatorColor)),
        alignment: .top
      )
      .alignmentGuide(.top) { dimensions in
        dimensions[VerticalAlignment.bottom]
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private var expandedContent: some View {
    VStack(spacing: 0) {
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
      .frame(maxHeight: 150)

      toolbarView
    }
  }

  // MARK: - Header

  private var headerView: some View {
    HStack(spacing: 8) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(width: 10)

          Image(systemName: "text.bubble.fill")
            .font(.caption)
            .foregroundColor(.secondary)

          Text("\(commentsState.commentCount) Comment\(commentsState.commentCount == 1 ? "" : "s")")
            .font(.caption.bold())
            .foregroundColor(.primary)

          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Only shown while collapsed — when expanded, the bottom toolbar
      // already exposes the same action.
      if !isExpanded {
        headerSendButton
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var headerSendButton: some View {
    let button = Button(action: onSendToCloud) {
      sendButtonLabel
        .foregroundColor(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.primary.opacity(0.3), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Send all comments to \(providerKind.rawValue) (⌘ ↵)")

    if isSendShortcutEnabled {
      button.keyboardShortcut(.return, modifiers: .command)
    } else {
      button
    }
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

      sendToolbarButton
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private var sendToolbarButton: some View {
    let button = Button(action: onSendToCloud) {
      sendButtonLabel
        .foregroundColor(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.primary.opacity(0.3), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help("Send all comments to \(providerKind.rawValue) (⌘ ↵)")

    if isSendShortcutEnabled {
      button.keyboardShortcut(.return, modifiers: .command)
    } else {
      button
    }
  }

  private var sendButtonLabel: some View {
    HStack(spacing: 4) {
      Image(systemName: "paperplane")
        .font(.caption)

      Text("Send \(commentsState.commentCount) to \(providerKind.rawValue)")
        .font(.caption.bold())

      Text("⌘ ↵")
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundColor(.secondary)
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
