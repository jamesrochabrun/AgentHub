//
//  DiffCommentsPanelView.swift
//  AgentHub
//
//  Created by Assistant on 1/29/26.
//

import SwiftUI

/// A floating, collapsible card that surfaces pending review comments over the diff.
///
/// It is a single morphing card: a persistent header bar (count + quick "Send"
/// + a rotating chevron) that grows downward to reveal the comment list and a
/// clear-all footer. Expansion animates the card's *height* (content is revealed
/// by the growing rounded clip) rather than scaling, so text never distorts.
///
/// The card *floats* above the diff content (it is never inline), so it neither
/// pushes the diff down nor collides with the surrounding "Create PR" bar —
/// callers attach it via `.overlay(alignment: .bottomTrailing)`.
struct DiffCommentsPanelView: View {

  // MARK: - Properties

  @Bindable var commentsState: DiffCommentsState
  let providerKind: SessionProviderKind
  let isSendShortcutEnabled: Bool
  let onSendToCloud: () -> Void

  @State private var isExpanded = false
  @State private var showClearConfirmation = false
  @State private var isSendHovered = false

  /// Spring used for the expand/collapse height morph and the chevron rotation.
  private let morph = Animation.spring(response: 0.4, dampingFraction: 0.82)
  private let cardRadius: CGFloat = 16

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

  // MARK: - Derived

  private var accent: Color { Color.brandPrimary(for: providerKind) }
  private var count: Int { commentsState.commentCount }
  private var countText: String { "\(count)" }
  private var commentsWord: String { count == 1 ? "Comment" : "Comments" }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      headerBar

      if isExpanded {
        hairline
        commentList
        hairline
        footerBar
      }
    }
    .frame(maxWidth: 460)
    .background(surfaceFill)
    // Clip so the revealing list/footer are unmasked by the growing card edge.
    .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
    .animation(morph, value: isExpanded)
    .padding(.trailing, 16)
    .padding(.bottom, 14)
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
      Text("This will remove all \(count) pending comments. This action cannot be undone.")
    }
  }

  // MARK: - Header

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
      .help(isExpanded ? "Collapse comments" : "Show comments")

      sendButton

      Button {
        toggleExpanded()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          // Points up when collapsed (expand upward), down when expanded.
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

  // MARK: - List

  private var commentList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(commentsState.orderedComments) { comment in
          DiffCommentRow(
            comment: comment,
            providerKind: providerKind,
            onSave: { newText in
              commentsState.updateComment(id: comment.id, newText: newText)
            },
            onDelete: {
              withAnimation(.easeInOut(duration: 0.2)) {
                commentsState.removeComment(id: comment.id)
              }
            }
          )

          if comment.id != commentsState.orderedComments.last?.id {
            hairline
              .padding(.leading, 14)
          }
        }
      }
    }
    .frame(maxHeight: 300)
  }

  // MARK: - Footer

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
      .help("Clear all comments")

      Spacer(minLength: 0)

      Text("Click a line in the diff to add another")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Shared Pieces

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

  @ViewBuilder
  private var sendButton: some View {
    let button = Button(action: onSendToCloud) {
      HStack(spacing: 6) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 11, weight: .semibold))

        Text("Send \(countText) to \(providerKind.rawValue)")
          .font(.system(size: 12, weight: .semibold))

        Text("⌘↵")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .opacity(0.8)
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
    .help("Send all comments to \(providerKind.rawValue) (⌘↵)")

    if isSendShortcutEnabled {
      button.keyboardShortcut(.return, modifiers: .command)
    } else {
      button
    }
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

  // MARK: - Actions

  private func toggleExpanded() {
    withAnimation(morph) {
      isExpanded.toggle()
    }
  }
}

// MARK: - Preview

#Preview {
  struct PreviewWrapper: View {
    @State var commentsState = DiffCommentsState()

    var body: some View {
      ZStack(alignment: .bottomTrailing) {
        LinearGradient(
          colors: [Color.gray.opacity(0.3), Color.black.opacity(0.5)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        DiffCommentsPanelView(
          commentsState: commentsState,
          providerKind: .claude,
          onSendToCloud: {}
        )
      }
      .frame(width: 800, height: 460)
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
