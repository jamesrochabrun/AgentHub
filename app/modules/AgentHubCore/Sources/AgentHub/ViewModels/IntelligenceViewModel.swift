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

  /// Orchestration service for parallel worktree operations
  private var orchestrationService: WorktreeOrchestrationService?

  /// Current loading state
  public private(set) var isLoading: Bool = false

  /// Last assistant response text
  public private(set) var lastResponse: String = ""

  /// Error message if any
  public private(set) var errorMessage: String?

  /// Working directory for Claude operations
  public var workingDirectory: String?

  /// Orchestration progress message
  public private(set) var orchestrationProgress: String?

  /// Detailed worktree creation progress
  public private(set) var worktreeProgress: WorktreeCreationProgress?

  /// Pending orchestration plan to execute after stream completes
  private var pendingOrchestrationPlan: OrchestrationPlan?

  /// Parsed orchestration plan captured during planning mode (exposed for smart launch)
  public private(set) var parsedOrchestrationPlan: OrchestrationPlan?

  /// When true, orchestration plans are captured instead of auto-executed
  private var isPlanningMode = false

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
  public init(
    claudeClient: ClaudeCode? = nil,
    gitService: GitWorktreeService? = nil,
    monitorService: CLISessionMonitorService? = nil
  ) {
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

    // Create orchestration service if dependencies provided
    if let gitService = gitService, let monitorService = monitorService {
      self.orchestrationService = WorktreeOrchestrationService(
        gitService: gitService,
        monitorService: monitorService,
        claudeClient: self.claudeClient
      )

      self.orchestrationService?.onProgress = { [weak self] progress in
        Task { @MainActor in
          self?.orchestrationProgress = progress.message
        }
      }

      self.orchestrationService?.onWorktreeProgress = { [weak self] progress in
        Task { @MainActor in
          self?.worktreeProgress = progress
        }
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
        // Execute pending orchestration AFTER stream completes (avoids race condition)
        if let plan = self.pendingOrchestrationPlan {
          self.pendingOrchestrationPlan = nil
          if self.isPlanningMode {
            // Capture for smart launch — don't auto-execute
            self.parsedOrchestrationPlan = plan
          } else {
            await self.executeOrchestrationPlan(plan)
          }
        }
        self.isLoading = false
        self.orchestrationProgress = nil
        self.worktreeProgress = nil
      }
    }

    streamProcessor.onError = { [weak self] error in
      Task { @MainActor in
        self?.isLoading = false
        self?.orchestrationProgress = nil
        self?.worktreeProgress = nil
        self?.errorMessage = error.localizedDescription
      }
    }

    // Store orchestration plan for execution after stream completes (avoid race condition)
    streamProcessor.onOrchestrationPlan = { [weak self] plan in
      self?.pendingOrchestrationPlan = plan
    }
  }

  private func executeOrchestrationPlan(_ plan: OrchestrationPlan) async {
    guard let orchestrationService = orchestrationService else {
      return
    }

    do {
      _ = try await orchestrationService.executePlan(plan)
    } catch {
      self.errorMessage = "Orchestration failed: \(error.localizedDescription)"
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
    orchestrationProgress = nil
    worktreeProgress = nil
    pendingOrchestrationPlan = nil
    isPlanningMode = false
    toolSteps = []
    isLoading = true

    AppLogger.intelligence.info("sendMessage: starting (\(text.prefix(80))…)")

    // Determine if we're in orchestration mode (working directory selected)
    let isOrchestrationMode = workingDirectory != nil && orchestrationService != nil

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

        // Use orchestration system prompt if in orchestration mode
        if isOrchestrationMode, let workingDir = workingDirectory {
          options.systemPrompt = """
            \(WorktreeOrchestrationTool.systemPrompt)

            CONTEXT:
            - Working directory: \(workingDir)
            - Use this path as the modulePath in your orchestration plan
            """

          // Use disallowedTools to prevent file modifications during orchestration
          options.disallowedTools = ["Edit", "MultiEdit", "Write", "AskUserQuestion", "Bash"]
        }

        // Send the prompt
        let result = try await claudeClient.runSinglePrompt(
          prompt: text,
          outputFormat: .streamJson,
          options: options
        )

        // Process the result
        await processResult(result)
      } catch {
        await MainActor.run {
          self.isLoading = false
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  /// Cancel the current request
  public func cancelRequest() {
    AppLogger.intelligence.info("cancelRequest: cancelling active request")
    streamProcessor.cancelStream()
    claudeClient.cancel()
    isLoading = false
  }

  /// Generate a plan using Claude Code SDK in plan mode.
  /// Streams a structured implementation plan without executing any changes.
  /// Sets `isPlanningMode` so any detected `<orchestration-plan>` is captured
  /// in `parsedOrchestrationPlan` instead of being auto-executed.
  public func generatePlan(prompt: String, workingDirectory: String) {
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard !isLoading else { return }

    // Reset state
    lastResponse = ""
    errorMessage = nil
    pendingOrchestrationPlan = nil
    parsedOrchestrationPlan = nil
    isPlanningMode = true
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

  /// System prompt optimized for planning (no execution).
  static func planningSystemPrompt(workingDirectory: String) -> String {
    """
    You are a senior software engineering planner. Your job is to explore the \
    codebase and then design a detailed, actionable implementation plan.

    CONTEXT:
    - Working directory: \(workingDirectory)

    PHASE 1 — EXPLORE (use tools):
    Use Read, Grep, Glob, and Bash (read-only commands like ls, git log, git diff, \
    cat, find) to understand the codebase structure, existing patterns, and relevant \
    files before planning. Explore thoroughly — the better you understand the code, \
    the better your plan will be.

    PHASE 2 — PLAN (output markdown):
    After exploring, present a clear structured plan in markdown:
    - **Summary**: One-paragraph overview of the approach
    - **Files to modify**: List each file with what changes are needed and why
    - **Files to create** (if any): New files with their purpose
    - **Implementation order**: Numbered steps in dependency order
    - **Risks / considerations**: Edge cases, breaking changes, testing notes

    RULES:
    - Do NOT execute any changes (no Edit, Write, or MultiEdit)
    - Do NOT ask the user questions
    - Bash is allowed ONLY for read-only commands (git, ls, find, cat, head, wc)
    - Be specific: reference actual file paths, function names, and line ranges
    - Use markdown formatting
    """
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
