//
//  IntelligenceStreamProcessor.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import Foundation
import Combine
import ClaudeCodeSDK
import SwiftAnthropic

/// Simplified stream processor for the Intelligence feature.
/// Processes Claude's streaming responses and triggers callbacks for tool calls/results.
@MainActor
final class IntelligenceStreamProcessor {

  private var cancellables = Set<AnyCancellable>()
  private var activeContinuation: CheckedContinuation<Void, Never>?
  private var continuationResumed = false

  /// Accumulated text for detecting orchestration plans
  private var accumulatedText = ""
  /// Flag to prevent processing the same plan multiple times
  private var planAlreadyProcessed = false

  // Callbacks
  var onTextReceived: ((String) -> Void)?
  var onToolUse: ((String, String) -> Void)?
  var onToolResult: ((String) -> Void)?
  var onComplete: (() -> Void)?
  var onError: ((Error) -> Void)?

  /// Callback for orchestration tool calls
  var onOrchestrationPlan: ((OrchestrationPlan) -> Void)?

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

  /// Process a streaming response from Claude Code SDK
  func processStream(_ publisher: AnyPublisher<ResponseChunk, Error>) async {
    continuationResumed = false
    accumulatedText = ""
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

          self.onError?(ClaudeCodeError.timeout(120.0))
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

  private func processChunk(_ chunk: ResponseChunk) {
    switch chunk {
    case .initSystem:
      break

    case .assistant(let message):
      processAssistantMessage(message)

    case .user(let userMessage):
      processUserMessage(userMessage)

    case .result:
      break
    }
  }

  private func processAssistantMessage(_ message: AssistantMessage) {
    for content in message.message.content {
      switch content {
      case .text(let textContent, _):
        if !textContent.isEmpty {
          onTextReceived?(textContent)

          // Accumulate text for orchestration plan detection
          accumulatedText += textContent
          checkForOrchestrationPlan()
        }

      case .toolUse(let toolUse):
        let inputDescription = toolUse.input.formattedDescription()
        onToolUse?(toolUse.name, inputDescription)

        // Check for orchestration tool call (legacy approach)
        if toolUse.name == WorktreeOrchestrationTool.toolName {
          handleOrchestrationToolCall(toolUse.input)
        }

      case .toolResult(let toolResult):
        let resultContent = formatToolResult(toolResult.content)
        onToolResult?(resultContent)

      case .thinking:
        break

      default:
        break
      }
    }
  }

  /// Check accumulated text for orchestration plan JSON
  private func checkForOrchestrationPlan() {
    // Don't process if already handled
    guard !planAlreadyProcessed else { return }

    // Check if we have complete plan markers
    guard WorktreeOrchestrationTool.containsPlanMarkers(accumulatedText) else { return }

    // Try to parse the plan
    guard let plan = WorktreeOrchestrationTool.parseFromText(accumulatedText) else {
      return
    }

    // Mark as processed to avoid re-triggering
    planAlreadyProcessed = true

    // Trigger the callback
    onOrchestrationPlan?(plan)
  }

  private func processUserMessage(_ userMessage: UserMessage) {
    for content in userMessage.message.content {
      if case .toolResult(let toolResult) = content {
        let resultContent = formatToolResult(toolResult.content)
        onToolResult?(resultContent)
      }
    }
  }

  private func formatToolResult(_ content: MessageResponse.Content.ToolResultContent) -> String {
    switch content {
    case .string(let str):
      return str
    case .items(let items):
      return items.compactMap { item in
        item.text
      }.joined(separator: "\n")
    }
  }

  // MARK: - Orchestration Tool Handling

  private func handleOrchestrationToolCall(_ input: [String: MessageResponse.Content.DynamicContent]) {
    // Convert DynamicContent to standard types for parsing
    let convertedInput = convertDynamicContent(input)

    // Parse the orchestration plan
    guard let plan = WorktreeOrchestrationTool.parseInput(convertedInput) else {
      return
    }

    // Trigger the callback
    onOrchestrationPlan?(plan)
  }

  private func convertDynamicContent(_ input: [String: MessageResponse.Content.DynamicContent]) -> [String: Any] {
    var result: [String: Any] = [:]

    for (key, value) in input {
      result[key] = convertDynamicValue(value)
    }

    return result
  }

  private func convertDynamicValue(_ value: MessageResponse.Content.DynamicContent) -> Any {
    switch value {
    case .string(let str):
      return str
    case .integer(let num):
      return num
    case .double(let num):
      return num
    case .bool(let bool):
      return bool
    case .array(let arr):
      return arr.map { convertDynamicValue($0) }
    case .dictionary(let dict):
      var result: [String: Any] = [:]
      for (k, v) in dict {
        result[k] = convertDynamicValue(v)
      }
      return result
    case .null:
      return NSNull()
    }
  }
}
