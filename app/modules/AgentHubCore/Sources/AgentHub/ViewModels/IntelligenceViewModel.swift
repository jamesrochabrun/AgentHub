//
//  IntelligenceViewModel.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import Foundation
import ClaudeCodeSDK
import Combine
import SwiftAnthropic

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

  /// Last assistant response text (accumulated across all messages)
  public private(set) var lastResponse: String = ""

  /// Text from the most recent assistant message only (excludes exploration/tool steps)
  public private(set) var lastAssistantMessage: String = ""

  /// Error message if any
  public private(set) var errorMessage: String?

  /// Parsed orchestration plan captured during planning mode (exposed for smart launch)
  public private(set) var parsedOrchestrationPlan: OrchestrationPlan?

  /// Steps tracked during tool use (planning / exploration)
  public struct ToolStep: Identifiable {
    public let id = UUID()
    public let toolName: String
    public let summary: String
    public var isComplete: Bool = false
  }

  public private(set) var toolSteps: [ToolStep] = []

  // MARK: - Initialization

  /// Creates a new IntelligenceViewModel with a Claude Code client
  public init(claudeClient: ClaudeCode? = nil) {
    // Create Claude client
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

    streamProcessor.onToolUse = { [weak self] (toolName: String, _: String, input: [String: MessageResponse.Content.DynamicContent]) in
      guard let self else { return }
      let summary = Self.extractToolSummary(toolName: toolName, input: input)
      self.toolSteps.append(ToolStep(toolName: toolName, summary: summary))
      AppLogger.intelligence.info("Tool call: \(toolName) — \(summary)")
    }

    streamProcessor.onToolResult = { [weak self] _ in
      guard let self else { return }
      if let index = self.toolSteps.lastIndex(where: { !$0.isComplete }) {
        self.toolSteps[index].isComplete = true
      }
    }

    streamProcessor.onComplete = { [weak self] in
      guard let self = self else { return }
      Task { @MainActor in
        self.isLoading = false
      }
    }

    streamProcessor.onError = { [weak self] error in
      Task { @MainActor in
        self?.isLoading = false
        self?.errorMessage = error.localizedDescription
      }
    }

    streamProcessor.onOrchestrationPlan = { [weak self] plan in
      self?.parsedOrchestrationPlan = plan
    }

    streamProcessor.onLastAssistantMessage = { [weak self] text in
      self?.lastAssistantMessage = text
    }

    streamProcessor.onResultMessage = { [weak self] resultMessage in
      guard let self, self.parsedOrchestrationPlan == nil,
            let resultText = resultMessage.result, !resultText.isEmpty else { return }
      // Try parsing orchestration plan from the result message text
      if let plan = WorktreeOrchestrationTool.parseFromText(resultText)
           ?? WorktreeOrchestrationTool.parseJSONFromText(resultText) {
        self.parsedOrchestrationPlan = plan
        AppLogger.intelligence.info("Parsed orchestration plan from ResultMessage (\(plan.sessions.count) sessions)")
      }
    }
  }

  // MARK: - Public Methods

  /// Cancel the current request
  public func cancelRequest() {
    AppLogger.intelligence.info("cancelRequest: cancelling active request")
    streamProcessor.cancelStream()
    claudeClient.cancel()
    isLoading = false
  }

  /// Generate a plan using Claude Code SDK in plan mode.
  /// Streams a structured implementation plan without executing any changes.
  /// Any detected `<orchestration-plan>` is captured in `parsedOrchestrationPlan`.
  public func generatePlan(prompt: String, workingDirectory: String) {
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard !isLoading else { return }

    // Reset state
    lastResponse = ""
    lastAssistantMessage = ""
    errorMessage = nil
    parsedOrchestrationPlan = nil
    toolSteps = []
    isLoading = true

    AppLogger.intelligence.info("generatePlan: starting for prompt (\(prompt.prefix(80))…)")

    Task {
      do {
        claudeClient.configuration.workingDirectory = workingDirectory

        var options = ClaudeCodeOptions()
        options.permissionMode = .plan
        options.disallowedTools = ["AskUserQuestion"]
        options.systemPrompt = """
          You are a task planner. Analyze the user's request and break it into \
          parallel tasks that can each be handled by a separate coding agent.

          CONTEXT:
          - Working directory: \(workingDirectory)

          OUTPUT FORMAT:
          1. A brief markdown summary of the overall approach
          2. For each task: a heading, what it involves, and key files
          3. End with an <orchestration-plan> JSON block:

          <orchestration-plan>
          {
            "modulePath": "\(workingDirectory)",
            "sessions": [
              {
                "description": "Brief task description",
                "branchName": "descriptive-branch-name",
                "sessionType": "parallel",
                "prompt": "Detailed prompt for this specific task with file paths and requirements"
              }
            ]
          }
          </orchestration-plan>

          RULES:
          - Each session prompt must be self-contained and detailed enough for an agent to execute independently
          - Branch names: lowercase, hyphenated, descriptive (e.g., "add-unit-tests", "update-readme")
          - Keep exploration minimal — use Glob/Grep only to identify key files, don't read entire files
          - If the request is a single task, still output one session in the plan
          """

        let result = try await claudeClient.runSinglePrompt(
          prompt: prompt,
          outputFormat: .streamJson,
          options: options
        )

        await processResult(result)
        AppLogger.intelligence.info("generatePlan: completed (\(self.lastResponse.count) chars)")
      } catch {
        AppLogger.intelligence.error("generatePlan: error — \(error.localizedDescription)")
        await MainActor.run {
          self.isLoading = false
          self.errorMessage = error.localizedDescription
        }
      }
    }
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
      lastResponse = text
      isLoading = false

    case .json(let resultMessage):
      lastResponse = resultMessage.result ?? ""
      isLoading = false
    }
  }

  // MARK: - Tool Summary Extraction

  /// Extracts the most useful parameter per tool type for concise display.
  static func extractToolSummary(
    toolName: String,
    input: [String: MessageResponse.Content.DynamicContent]
  ) -> String {
    switch toolName {
    case "Read", "Edit", "Write", "MultiEdit":
      if case .string(let path) = input["file_path"] {
        return shortenPath(path)
      }
    case "Bash":
      if case .string(let cmd) = input["command"] {
        return String(cmd.prefix(80))
      }
    case "Grep":
      if case .string(let pattern) = input["pattern"] {
        return pattern
      }
    case "Glob":
      if case .string(let pattern) = input["pattern"] {
        return pattern
      }
    case "WebSearch":
      if case .string(let query) = input["query"] {
        return query
      }
    case "LSP":
      if case .string(let op) = input["operation"] {
        return op
      }
    default:
      break
    }

    // Fallback: first string value from input
    for (_, value) in input {
      if case .string(let str) = value {
        return String(str.prefix(60))
      }
    }
    return ""
  }

  /// Returns the last 3 path components for compact display.
  private static func shortenPath(_ path: String) -> String {
    let components = path.split(separator: "/")
    if components.count <= 3 {
      return path
    }
    return components.suffix(3).joined(separator: "/")
  }
}
