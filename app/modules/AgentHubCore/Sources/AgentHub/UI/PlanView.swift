//
//  PlanView.swift
//  AgentHub
//
//  Created by Assistant on 1/20/26.
//

#if canImport(AppKit)
import AppKit
#endif
import ClaudeCodeSDK
import SwiftUI

// MARK: - PlanView

/// Sheet view to display plan markdown content from a session's plan file.
///
/// Shows a header with file information and session context, followed by
/// the rendered markdown content. Handles async loading and error states.
/// Supports a review mode where users can annotate individual lines and
/// send batch feedback back to the terminal (option 4).
public struct PlanView: View {
  let session: CLISession
  let planState: PlanState
  let onDismiss: () -> Void
  var isEmbedded: Bool = false
  var providerKind: SessionProviderKind = .claude
  var onSendFeedback: ((String, CLISession) -> Void)?

  @State private var content: String?
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var commentsState = DiffCommentsState()
  @State private var activeLineIndex: Int?
  @State private var isReviewMode: Bool = false

  public init(
    session: CLISession,
    planState: PlanState,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false,
    providerKind: SessionProviderKind = .claude,
    onSendFeedback: ((String, CLISession) -> Void)? = nil
  ) {
    self.session = session
    self.planState = planState
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.providerKind = providerKind
    self.onSendFeedback = onSendFeedback
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      Divider()

      // Content
      if isLoading {
        loadingState
      } else if let error = errorMessage {
        errorState(error)
      } else if let content = content {
        if isReviewMode {
          reviewContent(content)
        } else {
          markdownContent(content)
        }
      }

      Divider()

      // Footer with action buttons
      footer
    }
    .frame(
      minWidth: isEmbedded ? 300 : 700, idealWidth: isEmbedded ? .infinity : 900, maxWidth: .infinity,
      minHeight: isEmbedded ? 300 : 550, idealHeight: isEmbedded ? .infinity : 750, maxHeight: .infinity
    )
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
    .task {
      await loadPlanContent()
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Spacer()

      // Copy button
      Button(action: copyPlanContent) {
        HStack(spacing: 4) {
          Image(systemName: "doc.on.doc")
          Text("Copy")
        }
      }
      .buttonStyle(.bordered)
      .disabled(content == nil)
      .help("Copy plan to clipboard")
    }
    .padding()
    .background(Color.surfaceElevated)
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      HStack(spacing: 8) {
        Image(systemName: "list.bullet.clipboard")
          .font(.title3)
          .foregroundColor(.brandPrimary)

        Text("Plan")
          .font(.title3.weight(.semibold))

        Text(planState.fileName)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.secondary)
      }

      Spacer()

      // Session info
      HStack(spacing: 8) {
        Text(session.shortId)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      // Review mode toggle (only when feedback is supported)
      if onSendFeedback != nil {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            isReviewMode.toggle()
            if !isReviewMode {
              activeLineIndex = nil
            }
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: isReviewMode ? "doc.text.fill" : "pencil.and.list.clipboard")
              .font(.caption)
            Text(isReviewMode ? "Preview" : "Review")
              .font(.caption)
          }
          .overlay(alignment: .topTrailing) {
            if commentsState.hasComments && !isReviewMode {
              Circle()
                .fill(Color.brandPrimary(for: providerKind))
                .frame(width: 8, height: 8)
                .offset(x: 4, y: -4)
            }
          }
        }
        .buttonStyle(.bordered)
        .help(isReviewMode ? "Switch to rendered preview" : "Switch to review mode to annotate lines")
      }

      Button("Close") {
        onDismiss()
      }
    }
    .padding()
    .background(Color.surfaceElevated)
  }

  // MARK: - Loading State

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.small)
      Text("Loading plan...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Error State

  private func errorState(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundColor(.red)

      Text("Failed to load plan")
        .font(.headline)
        .foregroundColor(.secondary)

      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Markdown Content

  @Environment(\.colorScheme) private var colorScheme

  private func markdownContent(_ text: String) -> some View {
    ScrollView {
      MarkdownView(content: text, includeScrollView: false)
        .padding(DesignTokens.Spacing.lg)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
        .shadow(
          color: cardShadowColor,
          radius: 8,
          x: 0,
          y: 2
        )
        .padding(DesignTokens.Spacing.xl)
    }
    .background(Color.surfaceCanvas)
  }

  private var cardBackground: Color {
    colorScheme == .dark ? Color(white: 0.08) : Color.white
  }

  private var cardShadowColor: Color {
    colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.08)
  }

  // MARK: - Review Content

  private func reviewContent(_ text: String) -> some View {
    let lines = text.components(separatedBy: "\n")
    return VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
            planLineRow(index: idx, line: line, planFilePath: planState.filePath)
          }
        }
        .padding(DesignTokens.Spacing.md)
      }
      .background(Color.surfaceCanvas)

      if commentsState.hasComments {
        DiffCommentsPanelView(
          commentsState: commentsState,
          providerKind: providerKind,
          onSendToCloud: sendFeedbackToTerminal
        )
      }
    }
  }

  // MARK: - Plan Line Row

  @ViewBuilder
  private func planLineRow(index: Int, line: String, planFilePath: String) -> some View {
    let lineNumber = index + 1
    let hasComment = commentsState.hasComment(
      filePath: planFilePath,
      lineNumber: lineNumber,
      side: "plan"
    )

    VStack(alignment: .leading, spacing: 0) {
      // Clickable line row
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          activeLineIndex = (activeLineIndex == index ? nil : index)
        }
      } label: {
        HStack(spacing: 8) {
          // Line number
          Text("\(lineNumber)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(minWidth: 32, alignment: .trailing)

          // Comment indicator dot
          Circle()
            .fill(hasComment ? Color.brandPrimary(for: providerKind) : Color.clear)
            .frame(width: 6, height: 6)

          // Line content
          Text(line.isEmpty ? " " : line)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
          activeLineIndex == index
            ? Color.brandPrimary(for: providerKind).opacity(0.08)
            : Color.clear
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Inline editor — expands below the clicked line
      if activeLineIndex == index {
        InlineEditorView(
          lineNumber: lineNumber,
          side: "plan",
          fileName: planFilePath,
          errorMessage: nil,
          providerKind: providerKind,
          onSubmit: { message in
            let feedback = "Feedback on line \(lineNumber): \(message)"
            onSendFeedback?("\u{1B}[B\u{1B}[B\u{1B}[B\r\(feedback)", session)
            withAnimation { activeLineIndex = nil }
          },
          onAddComment: { message in
            commentsState.addComment(
              filePath: planFilePath,
              lineNumber: lineNumber,
              side: "plan",
              lineContent: line,
              text: message
            )
            if commentsState.commentCount == 1 {
              commentsState.isPanelExpanded = true
            }
            withAnimation { activeLineIndex = nil }
          },
          onDeleteComment: hasComment ? {
            commentsState.removeComment(
              filePath: planFilePath,
              lineNumber: lineNumber,
              side: "plan"
            )
            withAnimation { activeLineIndex = nil }
          } : nil,
          onDismiss: { withAnimation { activeLineIndex = nil } },
          initialText: commentsState.getComment(
            filePath: planFilePath,
            lineNumber: lineNumber,
            side: "plan"
          )?.text ?? "",
          isEditMode: hasComment
        )
        .padding(.leading, 48)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  // MARK: - Send Feedback to Terminal

  private func sendFeedbackToTerminal() {
    let comments = commentsState.orderedComments
    guard !comments.isEmpty else { return }

    var feedback = "Here is my feedback on the plan:\n"
    for comment in comments {
      feedback += "\n**Line \(comment.lineNumber)**: `\(comment.lineContent)`\n"
      feedback += "Feedback: \(comment.text)\n"
    }
    feedback += "\nPlease revise the plan based on this feedback."

    onSendFeedback?("\u{1B}[B\u{1B}[B\u{1B}[B\r\(feedback)", session)
    commentsState.clearAll()
    onDismiss()
  }

  // MARK: - Load Content

  private func loadPlanContent() async {
    isLoading = true
    errorMessage = nil

    do {
      // Expand tilde in path if present
      let expandedPath = (planState.filePath as NSString).expandingTildeInPath
      let fileURL = URL(fileURLWithPath: expandedPath)

      let text = try await Task.detached {
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
          throw PlanLoadError.invalidEncoding
        }
        return text
      }.value

      self.content = text
      self.isLoading = false
    } catch {
      self.errorMessage = error.localizedDescription
      self.isLoading = false
    }
  }

  // MARK: - Copy Plan Content

  private func copyPlanContent() {
    guard let content = content else { return }
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(content, forType: .string)
    #endif
  }

  // MARK: - Session Transcript Path

  private var sessionTranscriptPath: String {
    let sanitizedPath = session.projectPath.claudeProjectPathEncoded
    return "~/.claude/projects/\(sanitizedPath)/\(session.id).jsonl"
  }
}

// MARK: - PlanLoadError

private enum PlanLoadError: LocalizedError {
  case invalidEncoding

  var errorDescription: String? {
    switch self {
    case .invalidEncoding:
      return "File content is not valid UTF-8 text"
    }
  }
}

// MARK: - Preview

#Preview {
  PlanView(
    session: CLISession(
      id: "test-session-id",
      projectPath: "/Users/test/project",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 10,
      isActive: true
    ),
    planState: PlanState(filePath: "~/.claude/plans/test-plan.md"),
    onDismiss: {}
  )
}
