//
//  IntelligenceViewModel.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import Foundation
import ClaudeCodeSDK
import Combine

/// View model for the Intelligence feature.
/// Manages communication with Claude Code SDK and handles streaming responses.
@Observable
@MainActor
public final class IntelligenceViewModel {

  // MARK: - Properties

  /// The Claude Code client for SDK communication
  private var claudeClient: ClaudeCode

  /// Stream processor for handling responses
  private let streamProcessor = IntelligenceStreamProcessor()

  /// Current loading state
  public private(set) var isLoading: Bool = false

  /// Last assistant response text
  public private(set) var lastResponse: String = ""

  /// Error message if any
  public private(set) var errorMessage: String?

  /// Working directory for Claude operations
  public var workingDirectory: String?

  // MARK: - Initialization

  /// Creates a new IntelligenceViewModel with a Claude Code client
  public init(claudeClient: ClaudeCode? = nil) {
    if let client = claudeClient {
      self.claudeClient = client
    } else {
      // Create client with NVM support and local Claude path
      do {
        var config = ClaudeCodeConfiguration.withNvmSupport()
        config.enableDebugLogging = true

        let homeDir = NSHomeDirectory()

        // Add local Claude installation path (highest priority)
        let localClaudePath = "\(homeDir)/.claude/local"
        if FileManager.default.fileExists(atPath: localClaudePath) {
          config.additionalPaths.insert(localClaudePath, at: 0)
        }

        // Add common development tool paths
        config.additionalPaths.append(contentsOf: [
          "/usr/local/bin",
          "/opt/homebrew/bin",
          "/usr/bin",
          "\(homeDir)/.bun/bin",
          "\(homeDir)/.deno/bin",
          "\(homeDir)/.cargo/bin",
          "\(homeDir)/.local/bin"
        ])

        self.claudeClient = try ClaudeCodeClient(configuration: config)
      } catch {
        fatalError("Failed to create ClaudeCodeClient: \(error)")
      }
    }

    setupStreamCallbacks()
  }

  private func setupStreamCallbacks() {
    streamProcessor.onTextReceived = { [weak self] text in
      self?.lastResponse += text
    }

    streamProcessor.onToolUse = { toolName, input in
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      print("🔧 TOOL: \(toolName)")
      print("📥 INPUT: \(input.prefix(500))\(input.count > 500 ? "..." : "")")
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    streamProcessor.onToolResult = { result in
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      print("📤 RESULT: \(result.prefix(500))\(result.count > 500 ? "..." : "")")
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    streamProcessor.onComplete = { [weak self] in
      Task { @MainActor in
        self?.isLoading = false
      }
    }

    streamProcessor.onError = { [weak self] error in
      Task { @MainActor in
        self?.isLoading = false
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Public Methods

  /// Send a message to Claude Code
  /// - Parameter text: The user's prompt
  public func sendMessage(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard !isLoading else { return }

    // Reset state
    lastResponse = ""
    errorMessage = nil
    isLoading = true

    print("════════════════════════════════════════")
    print("🧠 INTELLIGENCE REQUEST")
    print("📝 Prompt: \(text)")
    print("════════════════════════════════════════")

    Task {
      do {
        // Configure working directory if set
        if let workingDir = workingDirectory {
          claudeClient.configuration.workingDirectory = workingDir
        }

        // Create options
        var options = ClaudeCodeOptions()
        // Use default permission mode for simple operations
        options.permissionMode = .default

        // Send the prompt
        let result = try await claudeClient.runSinglePrompt(
          prompt: text,
          outputFormat: .streamJson,
          options: options
        )

        // Process the result
        await processResult(result)
      } catch {
        print("❌ ERROR: \(error.localizedDescription)")
        await MainActor.run {
          self.isLoading = false
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  /// Cancel the current request
  public func cancelRequest() {
    print("⛔ Request cancelled by user")
    streamProcessor.cancelStream()
    claudeClient.cancel()
    isLoading = false
  }

  /// Update the Claude client
  public func updateClient(_ client: ClaudeCode) {
    self.claudeClient = client
  }

  // MARK: - Private Methods

  private func processResult(_ result: ClaudeCodeResult) async {
    switch result {
    case .stream(let publisher):
      await streamProcessor.processStream(publisher)

    case .text(let text):
      print("[Intelligence] Text result: \(text)")
      lastResponse = text
      isLoading = false

    case .json(let resultMessage):
      print("[Intelligence] JSON result - Cost: $\(String(format: "%.4f", resultMessage.totalCostUsd))")
      lastResponse = resultMessage.result ?? ""
      isLoading = false
    }
  }
}
