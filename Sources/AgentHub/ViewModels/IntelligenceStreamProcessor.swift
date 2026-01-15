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
/// Processes Claude's streaming responses and prints tool calls/results to console.
@MainActor
final class IntelligenceStreamProcessor {

  private var cancellables = Set<AnyCancellable>()
  private var activeContinuation: CheckedContinuation<Void, Never>?
  private var continuationResumed = false

  // Callbacks
  var onTextReceived: ((String) -> Void)?
  var onToolUse: ((String, String) -> Void)?
  var onToolResult: ((String) -> Void)?
  var onComplete: (() -> Void)?
  var onError: ((Error) -> Void)?

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
              print("[Intelligence] Stream completed")
              self.onComplete?()
            case .failure(let error):
              print("[Intelligence] Stream error: \(error.localizedDescription)")
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
    case .initSystem(let initMessage):
      print("[Intelligence] Session initialized: \(initMessage.sessionId)")

    case .assistant(let message):
      processAssistantMessage(message)

    case .user(let userMessage):
      processUserMessage(userMessage)

    case .result(let resultMessage):
      print("[Intelligence] Result received - Cost: $\(String(format: "%.4f", resultMessage.totalCostUsd))")
    }
  }

  private func processAssistantMessage(_ message: AssistantMessage) {
    for content in message.message.content {
      switch content {
      case .text(let textContent, _):
        if !textContent.isEmpty {
          print("[Intelligence] Assistant: \(textContent)")
          onTextReceived?(textContent)
        }

      case .toolUse(let toolUse):
        let inputDescription = toolUse.input.formattedDescription()
        print("[Intelligence] Tool Use: \(toolUse.name)")
        print("[Intelligence] Input: \(inputDescription)")
        onToolUse?(toolUse.name, inputDescription)

      case .toolResult(let toolResult):
        let resultContent = formatToolResult(toolResult.content)
        print("[Intelligence] Tool Result: \(resultContent)")
        onToolResult?(resultContent)

      case .thinking(let thinking):
        print("[Intelligence] Thinking: \(thinking.thinking.prefix(100))...")

      default:
        break
      }
    }
  }

  private func processUserMessage(_ userMessage: UserMessage) {
    for content in userMessage.message.content {
      if case .toolResult(let toolResult) = content {
        let resultContent = formatToolResult(toolResult.content)
        print("[Intelligence] Tool Result (user): \(resultContent)")
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
}
