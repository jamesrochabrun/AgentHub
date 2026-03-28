//
//  IntelligenceStreamProcessor.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import Foundation
import Combine

/// Simplified stream processor for the Intelligence feature.
/// Processes Claude's streaming responses and triggers callbacks for tool calls/results.
@MainActor
final class IntelligenceStreamProcessor {

  private var cancellables = Set<AnyCancellable>()
  private var activeContinuation: CheckedContinuation<Void, Never>?
  private var continuationResumed = false

  /// Accumulated text for detecting orchestration plans
  private var accumulatedText = ""
  /// Text from the current (most recent) assistant message only
  private var lastAssistantMessageText = ""
  /// Flag to prevent processing the same plan multiple times
  private var planAlreadyProcessed = false

  // Callbacks
  var onTextReceived: ((String) -> Void)?
  var onToolUse: ((String, String, [String: DynamicJSONValue]) -> Void)?
  var onToolResult: ((String) -> Void)?
  var onComplete: (() -> Void)?
  var onError: ((Error) -> Void)?

  /// Callback for orchestration tool calls
  var onOrchestrationPlan: ((OrchestrationPlan) -> Void)?

  /// Callback fired at the end of each assistant message with its full text
  var onLastAssistantMessage: ((String) -> Void)?

  /// Callback fired when a ResultMessage is received (carries final assembled text + metadata)
  var onResultMessage: ((CLIResultMessage) -> Void)?

  /// Cancels the current stream processing
  func cancelStream() {
    cancellables.forEach { $0.cancel() }
    cancellables.removeAll()

    guard !continuationResumed else { return }
    if let continuation = activeContinuation {
      continuationResumed = true
      activeContinuation = nil
      continuation.resume()
    }
  }

  /// Process a streaming response from CLI process service
  func processStream(_ publisher: AnyPublisher<StreamJSONChunk, Error>) async {
    continuationResumed = false
    accumulatedText = ""
    lastAssistantMessageText = ""
    planAlreadyProcessed = false

    await withCheckedContinuation { continuation in
      self.activeContinuation = continuation

      var hasReceivedData = false
      var subscription: AnyCancellable?

      // Timeout task
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
        if !hasReceivedData && !Task.isCancelled {
          guard let self = self else { return }
          subscription?.cancel()
          self.cancellables.removeAll()

          guard !self.continuationResumed else { return }
          self.continuationResumed = true
          self.activeContinuation = nil

          self.onError?(CLIProcessError.timeout(120.0))
          continuation.resume()
        }
      }

      subscription = publisher
        .receive(on: DispatchQueue.main)
        .sink(
          receiveCompletion: { [weak self] completion in
            timeoutTask.cancel()
            guard let self = self else {
              continuation.resume()
              return
            }

            switch completion {
            case .finished:
              self.onComplete?()
            case .failure(let error):
              self.onError?(error)
            }

            guard !self.continuationResumed else { return }
            self.continuationResumed = true
            self.activeContinuation = nil
            continuation.resume()

            self.cancellables.removeAll()
          },
          receiveValue: { [weak self] chunk in
            hasReceivedData = true
            timeoutTask.cancel()
            guard let self = self else { return }
            self.processChunk(chunk)
          }
        )

      if let subscription = subscription {
        subscription.store(in: &cancellables)
      }
    }
  }

  private func processChunk(_ chunk: StreamJSONChunk) {
    switch chunk {
    case .system:
      break

    case .assistant(let message):
      processAssistantMessage(message)

    case .user(let userMessage):
      processUserMessage(userMessage)

    case .result(let resultMessage):
      processResultMessage(resultMessage)
    }
  }

  private func processAssistantMessage(_ message: CLIAssistantMessage) {
    let needsSeparator = !accumulatedText.isEmpty

    // Reset per-message text so we capture only this message's content
    lastAssistantMessageText = ""

    for content in message.message.content {
      switch content {
      case .text(let textContent):
        if !textContent.isEmpty {
          let fullText = (needsSeparator ? "\n\n" : "") + textContent
          onTextReceived?(fullText)

          // Accumulate text for orchestration plan detection
          accumulatedText += fullText
          lastAssistantMessageText += textContent
          checkForOrchestrationPlan()
        }

      case .toolUse(let toolUse):
        let inputDescription = toolUse.input.formattedDescription()
        onToolUse?(toolUse.name, inputDescription, toolUse.input)

      case .toolResult(let toolResult):
        let resultContent = formatToolResult(toolResult.content)
        onToolResult?(resultContent)

      case .thinking:
        break

      case .unknown:
        break
      }
    }

    // Notify with the complete text of this assistant message
    if !lastAssistantMessageText.isEmpty {
      onLastAssistantMessage?(lastAssistantMessageText)
    }
  }

  /// Check accumulated text for orchestration plan JSON
  private func checkForOrchestrationPlan() {
    // Don't process if already handled
    guard !planAlreadyProcessed else { return }

    // Try marker-based parsing first, then fallback to bare JSON
    guard let plan = WorktreeOrchestrationTool.parseFromText(accumulatedText)
            ?? WorktreeOrchestrationTool.parseJSONFromText(accumulatedText) else {
      return
    }

    // Mark as processed to avoid re-triggering
    planAlreadyProcessed = true

    // Trigger the callback
    onOrchestrationPlan?(plan)
  }

  /// Process the final result message from Claude
  private func processResultMessage(_ resultMessage: CLIResultMessage) {
    // Forward metadata
    onResultMessage?(resultMessage)

    // If the result contains text, accumulate and check for plan
    if let resultText = resultMessage.result, !resultText.isEmpty {
      accumulatedText += "\n\n" + resultText
      onTextReceived?("\n\n" + resultText)
      checkForOrchestrationPlan()
    }
  }

  private func processUserMessage(_ userMessage: CLIUserMessage) {
    for content in userMessage.message.content {
      if case .toolResult(let toolResult) = content {
        let resultContent = formatToolResult(toolResult.content)
        onToolResult?(resultContent)
      }
    }
  }

  private func formatToolResult(_ content: CLIToolResultContent) -> String {
    switch content {
    case .string(let str):
      return str
    case .items(let items):
      return items.compactMap { item in
        item.text
      }.joined(separator: "\n")
    }
  }

}
