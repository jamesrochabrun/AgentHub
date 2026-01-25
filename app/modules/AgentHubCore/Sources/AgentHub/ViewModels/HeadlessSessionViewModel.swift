//
//  HeadlessSessionViewModel.swift
//  AgentHub
//
//  ViewModel for Claude Code headless mode conversations.
//  Manages streaming events and tool approval state.
//

import Foundation
import SwiftUI

// MARK: - HeadlessSessionViewModel

/// ViewModel for managing Claude Code headless mode conversations.
///
/// Consumes events from `ClaudeHeadlessService` and maintains conversation state
/// for display in `HeadlessConversationView`. Handles tool approval prompts by
/// setting `pendingToolApproval` which triggers a sheet in the UI.
///
/// ## Usage
/// ```swift
/// @State private var viewModel = HeadlessSessionViewModel()
///
/// var body: some View {
///   HeadlessConversationView(viewModel: viewModel)
///     .task {
///       await viewModel.startSession(
///         prompt: "Hello!",
///         workingDirectory: URL(fileURLWithPath: "/path/to/project")
///       )
///     }
/// }
/// ```
@MainActor
@Observable
public final class HeadlessSessionViewModel {

  // MARK: - Published State

  /// Messages in the conversation
  public var messages: [ConversationMessage] = []

  /// Pending tool approval request (shows sheet when non-nil)
  public var pendingToolApproval: ClaudeControlRequestEvent?

  /// Whether the session is currently processing
  public var isProcessing: Bool = false

  /// Current session ID from Claude
  public var sessionId: String?

  /// Error message to display
  public var error: String?

  // MARK: - Dependencies

  /// The headless service for process management
  private var headlessService: ClaudeHeadlessService?

  /// Current event stream task
  private var streamTask: Task<Void, Never>?

  // MARK: - Initialization

  public init() { }

  /// Configures the view model with a headless service.
  /// - Parameter service: The ClaudeHeadlessService to use
  public func configure(with service: ClaudeHeadlessService) {
    self.headlessService = service
  }

  // MARK: - Session Management

  /// Starts a new headless session with the given prompt.
  /// - Parameters:
  ///   - prompt: The user prompt to send
  ///   - workingDirectory: Working directory for the session
  public func startSession(prompt: String, workingDirectory: URL) async {
    await startSessionInternal(prompt: prompt, sessionId: nil, workingDirectory: workingDirectory)
  }

  /// Resumes an existing session with a new prompt.
  /// - Parameters:
  ///   - prompt: The follow-up prompt to send
  ///   - sessionId: The session ID to resume
  ///   - workingDirectory: Working directory for the session
  public func resumeSession(prompt: String, sessionId: String, workingDirectory: URL) async {
    await startSessionInternal(prompt: prompt, sessionId: sessionId, workingDirectory: workingDirectory)
  }

  /// Internal implementation for starting/resuming sessions.
  private func startSessionInternal(prompt: String, sessionId: String?, workingDirectory: URL) async {
    guard let service = headlessService else {
      error = "Headless service not configured"
      AppLogger.session.error("HeadlessSessionViewModel: service not configured")
      return
    }

    // Cancel any existing stream
    streamTask?.cancel()
    streamTask = nil

    // Reset state for new request
    error = nil
    isProcessing = true

    // Add user message to conversation
    let userMessage = ConversationMessage(
      timestamp: Date(),
      content: .user(text: prompt)
    )
    messages.append(userMessage)

    do {
      let eventStream = try await service.start(
        prompt: prompt,
        sessionId: sessionId,
        workingDirectory: workingDirectory
      )

      streamTask = Task { [weak self] in
        await self?.consumeEventStream(eventStream)
      }
    } catch {
      self.error = error.localizedDescription
      isProcessing = false
      AppLogger.session.error("HeadlessSessionViewModel: failed to start session - \(error)")
    }
  }

  /// Consumes events from the async stream and updates state.
  private func consumeEventStream(_ stream: AsyncThrowingStream<ClaudeEvent, Error>) async {
    do {
      for try await event in stream {
        guard !Task.isCancelled else { break }
        handleEvent(event)
      }
    } catch {
      if !Task.isCancelled {
        self.error = error.localizedDescription
        AppLogger.session.error("HeadlessSessionViewModel: stream error - \(error)")
      }
    }

    isProcessing = false
  }

  /// Handles a single event from the stream.
  private func handleEvent(_ event: ClaudeEvent) {
    switch event {
    case .system(let systemEvent):
      handleSystemEvent(systemEvent)

    case .assistant(let assistantEvent):
      handleAssistantEvent(assistantEvent)

    case .user(let userEvent):
      handleUserEvent(userEvent)

    case .toolResult(let toolResultEvent):
      handleToolResultEvent(toolResultEvent)

    case .controlRequest(let controlRequest):
      handleControlRequest(controlRequest)

    case .result(let resultEvent):
      handleResultEvent(resultEvent)

    case .unknown:
      AppLogger.session.debug("HeadlessSessionViewModel: received unknown event")
    }
  }

  // MARK: - Event Handlers

  private func handleSystemEvent(_ event: ClaudeSystemEvent) {
    if let newSessionId = event.sessionId {
      self.sessionId = newSessionId
      AppLogger.session.info("HeadlessSessionViewModel: session started - \(newSessionId)")
    }
  }

  private func handleAssistantEvent(_ event: ClaudeAssistantEvent) {
    // Check for error in event
    if let errorMessage = event.error {
      error = errorMessage
      return
    }

    // Update session ID if present
    if let newSessionId = event.sessionId {
      self.sessionId = newSessionId
    }

    // Process message content
    guard let message = event.message, let content = message.content else { return }

    for block in content {
      switch block {
      case .text(let text):
        let assistantMessage = ConversationMessage(
          timestamp: Date(),
          content: .assistant(text: text)
        )
        messages.append(assistantMessage)

      case .toolUse(let toolUse):
        // Extract input preview from tool input
        let inputPreview = extractInputPreview(from: toolUse.input)
        let toolMessage = ConversationMessage(
          timestamp: Date(),
          content: .toolUse(name: toolUse.name, input: inputPreview, id: toolUse.id)
        )
        messages.append(toolMessage)

      case .other:
        break
      }
    }
  }

  private func handleUserEvent(_ event: ClaudeUserEvent) {
    // User events typically contain tool results in headless mode
    guard let message = event.message, let content = message.content else { return }

    for block in content {
      switch block {
      case .toolResult(let result):
        // Add tool result message
        let resultMessage = ConversationMessage(
          timestamp: Date(),
          content: .toolResult(
            name: "Tool",
            success: !(result.isError ?? false),
            toolUseId: result.toolUseId
          )
        )
        messages.append(resultMessage)

      case .text:
        // Text blocks in user messages are rare in headless mode
        break

      case .other:
        break
      }
    }
  }

  private func handleToolResultEvent(_ event: ClaudeToolResultEvent) {
    guard let toolUseId = event.toolUseId else { return }

    let resultMessage = ConversationMessage(
      timestamp: Date(),
      content: .toolResult(
        name: "Tool",
        success: !(event.isError ?? false),
        toolUseId: toolUseId
      )
    )
    messages.append(resultMessage)
  }

  private func handleControlRequest(_ event: ClaudeControlRequestEvent) {
    // Set pending approval to show the sheet
    pendingToolApproval = event
    AppLogger.session.info("HeadlessSessionViewModel: tool approval requested - \(event.requestId)")
  }

  private func handleResultEvent(_ event: ClaudeResultEvent) {
    // Session completed
    isProcessing = false

    // Update session ID if present
    if let newSessionId = event.sessionId {
      self.sessionId = newSessionId
    }

    // Check for error
    if event.isError == true, let errorMessage = event.error ?? event.result {
      error = errorMessage
    }

    AppLogger.session.info("HeadlessSessionViewModel: session completed")
  }

  // MARK: - Tool Approval

  /// Approves the pending tool use request.
  /// - Parameter requestId: The request ID to approve
  public func approveToolUse(requestId: String) async {
    guard let service = headlessService else {
      error = "Headless service not configured"
      return
    }

    do {
      try await service.sendControlResponse(requestId: requestId, allow: true, updatedInput: nil)
      pendingToolApproval = nil
      AppLogger.session.info("HeadlessSessionViewModel: approved tool use - \(requestId)")
    } catch {
      self.error = error.localizedDescription
      AppLogger.session.error("HeadlessSessionViewModel: failed to approve - \(error)")
    }
  }

  /// Denies the pending tool use request.
  /// - Parameter requestId: The request ID to deny
  public func denyToolUse(requestId: String) async {
    guard let service = headlessService else {
      error = "Headless service not configured"
      return
    }

    do {
      try await service.sendControlResponse(requestId: requestId, allow: false, updatedInput: nil)
      pendingToolApproval = nil
      AppLogger.session.info("HeadlessSessionViewModel: denied tool use - \(requestId)")
    } catch {
      self.error = error.localizedDescription
      AppLogger.session.error("HeadlessSessionViewModel: failed to deny - \(error)")
    }
  }

  /// Cancels the current session.
  public func cancel() async {
    streamTask?.cancel()
    streamTask = nil

    if let service = headlessService {
      await service.stop()
    }

    isProcessing = false
    pendingToolApproval = nil
    AppLogger.session.info("HeadlessSessionViewModel: cancelled")
  }

  /// Clears all messages and resets state.
  public func clearConversation() {
    messages = []
    sessionId = nil
    error = nil
    pendingToolApproval = nil
  }

  // MARK: - Helpers

  /// Extracts a preview string from tool input JSON.
  private func extractInputPreview(from input: JSONValue) -> String? {
    guard let dict = input.dictionary else {
      return input.string
    }

    // Common input keys to preview
    let previewKeys = ["command", "file_path", "path", "pattern", "query", "content"]
    for key in previewKeys {
      if let value = dict[key] as? String, !value.isEmpty {
        return value
      }
    }

    return nil
  }
}
