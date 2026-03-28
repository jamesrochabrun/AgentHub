//
//  IntelligenceViewModel.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import Foundation
import Combine

/// View model for the Intelligence feature.
/// Manages communication with Claude CLI process and handles streaming responses.
@Observable
@MainActor
public final class IntelligenceViewModel {

  // MARK: - Properties

  /// The CLI process service for running Claude prompts (nil if CLI is unavailable)
  private var processService: CLIProcessServiceProtocol?

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

  /// Creates a new IntelligenceViewModel with a CLI process service
  public init(processService: CLIProcessServiceProtocol? = nil) {
    if let service = processService {
      self.processService = service
    } else {
      self.processService = Self.createDefaultProcessService()
    }

    setupStreamCallbacks()
  }

  private static func createDefaultProcessService() -> CLIProcessServiceProtocol? {
    let homeDir = NSHomeDirectory()
    var paths: [String] = []

    // Add local Claude installation path (highest priority)
    let localClaudePath = "\(homeDir)/.claude/local"
    if FileManager.default.fileExists(atPath: localClaudePath) {
      paths.append(localClaudePath)
    }

    // Add common development tool paths
    paths.append(contentsOf: [
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin",
      "\(homeDir)/.nvm/current/bin",
      "\(homeDir)/.bun/bin",
      "\(homeDir)/.deno/bin",
      "\(homeDir)/.cargo/bin",
      "\(homeDir)/.local/bin"
    ])

    return CLIProcessService(
      command: "claude",
      additionalPaths: paths,
      debugLogging: {
        #if DEBUG
        return true
        #else
        return false
        #endif
      }()
    )
  }

  private func setupStreamCallbacks() {
    streamProcessor.onTextReceived = { [weak self] text in
      self?.lastResponse += text
    }

    streamProcessor.onToolUse = { [weak self] (toolName: String, _: String, input: [String: DynamicJSONValue]) in
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
    processService?.cancel()
    isLoading = false
  }

  /// Generate a plan using Claude CLI in plan mode.
  /// Streams a structured implementation plan without executing any changes.
  /// Any detected `<orchestration-plan>` is captured in `parsedOrchestrationPlan`.
  public func generatePlan(prompt: String, workingDirectory: String) {
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard !isLoading else { return }
    guard processService != nil else {
      errorMessage = "Claude CLI not available. Please ensure Claude Code CLI is installed."
      return
    }

    // Reset state
    lastResponse = ""
    lastAssistantMessage = ""
    errorMessage = nil
    parsedOrchestrationPlan = nil
    toolSteps = []
    isLoading = true

    AppLogger.intelligence.info("generatePlan: starting for prompt (\(prompt.prefix(80))…)")

    Task {
      guard let processService else { return }

      let systemPrompt = """
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

      let publisher = processService.runStreamingPrompt(
        prompt: prompt,
        workingDirectory: workingDirectory,
        systemPrompt: systemPrompt,
        permissionMode: "plan",
        disallowedTools: ["AskUserQuestion"]
      )

      await streamProcessor.processStream(publisher)
      AppLogger.intelligence.info("generatePlan: completed (\(self.lastResponse.count) chars)")
    }
  }

  /// Update the process service
  public func updateService(_ service: CLIProcessServiceProtocol) {
    self.processService = service
  }

  // MARK: - Tool Summary Extraction

  /// Extracts the most useful parameter per tool type for concise display.
  static func extractToolSummary(
    toolName: String,
    input: [String: DynamicJSONValue]
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
