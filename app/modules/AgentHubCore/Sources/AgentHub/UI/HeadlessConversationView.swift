//
//  HeadlessConversationView.swift
//  AgentHub
//
//  Main conversation view for Claude Code headless mode.
//  Displays streaming messages and handles tool approval prompts.
//

import SwiftUI

// MARK: - HeadlessConversationView

/// Main conversation view for Claude Code headless mode sessions.
///
/// Displays messages from `HeadlessSessionViewModel` in a scrollable list,
/// with an input field for prompts at the bottom. Presents a sheet for tool
/// approval when `pendingToolApproval` is non-nil.
///
/// ## Usage
/// ```swift
/// @Environment(\.agentHub) private var agentHub
/// @State private var viewModel = HeadlessSessionViewModel()
///
/// var body: some View {
///   HeadlessConversationView(viewModel: viewModel)
///     .onAppear {
///       if let provider = agentHub {
///         viewModel.configure(with: provider.headlessService)
///       }
///     }
/// }
/// ```
public struct HeadlessConversationView: View {
  /// The view model managing conversation state
  @Bindable var viewModel: HeadlessSessionViewModel

  /// Working directory for the session
  let workingDirectory: URL

  /// Input text state
  @State private var inputText: String = ""

  /// Focus state for the input field
  @FocusState private var isInputFocused: Bool

  /// Anchor ID for scroll-to-bottom
  private let bottomAnchorID = "headless-conversation-bottom"

  /// Creates a new headless conversation view.
  /// - Parameters:
  ///   - viewModel: The view model managing conversation state
  ///   - workingDirectory: Working directory for Claude sessions
  public init(viewModel: HeadlessSessionViewModel, workingDirectory: URL) {
    self.viewModel = viewModel
    self.workingDirectory = workingDirectory
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Messages list
      messagesScrollView

      // Error banner (if any)
      if let errorMessage = viewModel.error {
        errorBanner(message: errorMessage)
      }

      // Input field
      Divider()
      inputField
    }
    .sheet(isPresented: showToolApprovalSheet) {
      if let approval = viewModel.pendingToolApproval {
        ToolApprovalSheet(
          controlRequest: approval,
          onApprove: {
            Task {
              await viewModel.approveToolUse(requestId: approval.requestId)
            }
          },
          onDeny: {
            Task {
              await viewModel.denyToolUse(requestId: approval.requestId)
            }
          }
        )
      }
    }
  }

  // MARK: - Computed Properties

  /// Binding for showing the tool approval sheet
  private var showToolApprovalSheet: Binding<Bool> {
    Binding(
      get: { viewModel.pendingToolApproval != nil },
      set: { newValue in
        if !newValue {
          viewModel.pendingToolApproval = nil
        }
      }
    )
  }

  // MARK: - Messages List

  private var messagesScrollView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if viewModel.messages.isEmpty && !viewModel.isProcessing {
            emptyState
          } else {
            ForEach(viewModel.messages) { message in
              HeadlessMessageView(
                message: message,
                toolResultMap: buildToolResultMap()
              )
              .id(message.id)
            }

            // Processing indicator
            if viewModel.isProcessing {
              processingIndicator
            }
          }

          // Invisible anchor for scroll-to-bottom
          Color.clear
            .frame(height: 1)
            .id(bottomAnchorID)
        }
        .padding(12)
      }
      .onChange(of: viewModel.messages.count) { _, _ in
        scrollToBottom(proxy: proxy)
      }
      .onChange(of: viewModel.isProcessing) { _, _ in
        scrollToBottom(proxy: proxy)
      }
    }
  }

  private func scrollToBottom(proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.2)) {
      proxy.scrollTo(bottomAnchorID, anchor: .bottom)
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "sparkles")
        .font(.system(size: 24))
        .foregroundColor(.secondary)

      Text("Headless Mode")
        .font(.headline)
        .foregroundColor(.primary)

      Text("Send a message to start a conversation")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }

  // MARK: - Processing Indicator

  private var processingIndicator: some View {
    HStack(spacing: 8) {
      ProgressView()
        .scaleEffect(0.8)

      Text("Claude is thinking...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Error Display (Inline)

  private func errorBanner(message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(Color.Chat.toolError)
        .font(.caption)

      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)

      Spacer()

      Button(action: { viewModel.error = nil }) {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.secondary)
          .font(.caption)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Input Field

  private var inputField: some View {
    HStack(spacing: 8) {
      TextField("Message Claude...", text: $inputText)
        .textFieldStyle(.plain)
        .font(.body)
        .focused($isInputFocused)
        .disabled(viewModel.isProcessing)
        .onSubmit {
          sendMessage()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )

      // Send button
      Button(action: sendMessage) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 24))
          .foregroundColor(sendButtonColor)
      }
      .buttonStyle(.plain)
      .disabled(!canSend)
      .help("Send message")

      // Cancel button (when processing)
      if viewModel.isProcessing {
        Button(action: cancelSession) {
          Image(systemName: "stop.circle.fill")
            .font(.system(size: 24))
            .foregroundColor(Color.Chat.toolError)
        }
        .buttonStyle(.plain)
        .help("Cancel")
      }
    }
    .padding(12)
  }

  private var canSend: Bool {
    !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isProcessing
  }

  private var sendButtonColor: Color {
    canSend ? Color.primaryPurple : .secondary
  }

  // MARK: - Actions

  private func sendMessage() {
    let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty, !viewModel.isProcessing else { return }

    let prompt = trimmedText
    inputText = ""

    Task {
      if let existingSessionId = viewModel.sessionId {
        await viewModel.resumeSession(
          prompt: prompt,
          sessionId: existingSessionId,
          workingDirectory: workingDirectory
        )
      } else {
        await viewModel.startSession(
          prompt: prompt,
          workingDirectory: workingDirectory
        )
      }
    }
  }

  private func cancelSession() {
    Task {
      await viewModel.cancel()
    }
  }

  // MARK: - Tool Result Mapping

  /// Builds a map of tool use IDs to their results for rendering tool cards.
  private func buildToolResultMap() -> [String: ToolCallCard.ToolResult] {
    var resultMap: [String: ToolCallCard.ToolResult] = [:]

    for message in viewModel.messages {
      switch message.content {
      case .toolResult(_, let success, let toolUseId):
        resultMap[toolUseId] = success ? .success : .failure
      default:
        break
      }
    }

    // Mark pending tool uses
    for message in viewModel.messages {
      switch message.content {
      case .toolUse(_, _, let id):
        if resultMap[id] == nil {
          resultMap[id] = .pending
        }
      default:
        break
      }
    }

    return resultMap
  }
}

// MARK: - HeadlessMessageView

/// Routes a conversation message to the appropriate view component.
private struct HeadlessMessageView: View {
  let message: ConversationMessage
  let toolResultMap: [String: ToolCallCard.ToolResult]

  var body: some View {
    switch message.content {
    case .user(let text):
      UserMessageBubble(text: text, timestamp: message.timestamp)

    case .assistant(let text):
      HeadlessAssistantMessageView(text: text, timestamp: message.timestamp)

    case .toolUse(let name, let input, let id):
      ToolCallCard(
        toolName: name,
        input: input,
        result: toolResultMap[id],
        timestamp: message.timestamp
      )

    case .toolResult:
      // Tool results are rendered as part of the tool card state
      EmptyView()

    case .thinking:
      ThinkingIndicator(timestamp: message.timestamp)
    }
  }
}

// MARK: - HeadlessAssistantMessageView

/// Assistant message view for headless conversations.
/// Extends the basic AssistantMessageView with headless-specific styling.
private struct HeadlessAssistantMessageView: View {
  let text: String
  let timestamp: Date

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Assistant icon
      Image(systemName: "sparkles")
        .font(.system(size: 18))
        .foregroundColor(Color.Chat.assistantPrimary)
        .frame(width: 20, height: 20)

      VStack(alignment: .leading, spacing: 4) {
        // Timestamp
        Text(formatTime(timestamp))
          .font(.caption2)
          .foregroundColor(.secondary)

        // Message text
        Text(text)
          .font(.body)
          .foregroundColor(.primary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.Chat.assistantPrimary.opacity(0.06))
    )
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}

// MARK: - ThinkingIndicator

/// Animated thinking indicator for when Claude is processing.
private struct ThinkingIndicator: View {
  let timestamp: Date

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "brain.head.profile")
        .font(.system(size: 14))
        .foregroundColor(Color.Chat.thinking)

      Text("Thinking...")
        .font(.caption)
        .foregroundColor(.secondary)
        .italic()

      Spacer()

      Text(formatTime(timestamp))
        .font(.caption2)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - Preview

#Preview("Headless Conversation") {
  let viewModel = HeadlessSessionViewModel()

  return HeadlessConversationView(
    viewModel: viewModel,
    workingDirectory: URL(fileURLWithPath: "/Users/test/project")
  )
  .frame(width: 500, height: 600)
  .onAppear {
    // Add sample messages for preview
    viewModel.messages = [
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-120),
        content: .user(text: "Can you help me create a Swift package?")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-110),
        content: .assistant(text: "I'll help you create a Swift package. Let me first check the current directory structure.")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-100),
        content: .toolUse(name: "Bash", input: "ls -la", id: "tool-1")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-95),
        content: .toolResult(name: "Bash", success: true, toolUseId: "tool-1")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-90),
        content: .assistant(text: "I can see the directory is empty. I'll create the package structure now.")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-80),
        content: .toolUse(name: "Bash", input: "swift package init --type library", id: "tool-2")
      )
    ]
    viewModel.isProcessing = true
  }
}

#Preview("Empty State") {
  HeadlessConversationView(
    viewModel: HeadlessSessionViewModel(),
    workingDirectory: URL(fileURLWithPath: "/Users/test/project")
  )
  .frame(width: 500, height: 400)
}

#Preview("With Error") {
  let viewModel = HeadlessSessionViewModel()
  viewModel.error = "Authentication failed. Please check your API key."

  return HeadlessConversationView(
    viewModel: viewModel,
    workingDirectory: URL(fileURLWithPath: "/Users/test/project")
  )
  .frame(width: 500, height: 400)
}
