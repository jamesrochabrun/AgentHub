//
//  ClaudeHeadlessService.swift
//  AgentHub
//
//  Service for running Claude Code in headless mode with JSONL streaming.
//

import Foundation
import os

// MARK: - ClaudeHeadlessError

/// Errors that can occur during headless Claude operations.
public enum ClaudeHeadlessError: LocalizedError, Sendable {
  /// Failed to find the Claude CLI executable
  case claudeNotFound

  /// Failed to start the Claude process
  case processStartFailed(String)

  /// The process terminated unexpectedly
  case processTerminated(Int32)

  /// Failed to parse a JSONL line
  case parseError(String)

  /// Authentication failed
  case authenticationFailed(String)

  /// No session is currently running
  case noActiveSession

  /// Session was cancelled
  case cancelled

  /// Failed to write to stdin
  case stdinWriteFailed(String)

  /// Timeout waiting for response
  case timeout

  public var errorDescription: String? {
    switch self {
    case .claudeNotFound:
      return "Claude CLI not found. Please ensure Claude Code is installed."
    case .processStartFailed(let message):
      return "Failed to start Claude process: \(message)"
    case .processTerminated(let code):
      return "Claude process terminated with exit code \(code)"
    case .parseError(let message):
      return "Failed to parse JSONL: \(message)"
    case .authenticationFailed(let message):
      return "Authentication failed: \(message)"
    case .noActiveSession:
      return "No active Claude session"
    case .cancelled:
      return "Session was cancelled"
    case .stdinWriteFailed(let message):
      return "Failed to write to stdin: \(message)"
    case .timeout:
      return "Operation timed out"
    }
  }
}

// MARK: - ControlResponse

/// Internal type for encoding control responses to stdin.
private struct ControlResponse: Encodable {
  let type: String = "control_response"
  let response: ResponsePayload

  struct ResponsePayload: Encodable {
    let subtype: String = "success"
    let requestId: String
    let response: BehaviorResponse

    private enum CodingKeys: String, CodingKey {
      case subtype
      case requestId = "request_id"
      case response
    }
  }

  struct BehaviorResponse: Encodable {
    let behavior: String
  }
}

// MARK: - ClaudeHeadlessService

/// Service for running Claude Code in headless mode.
///
/// This actor manages the Claude CLI process lifecycle, parses JSONL events
/// from stdout, and handles stdin communication for control responses.
///
/// ## Usage
/// ```swift
/// let service = ClaudeHeadlessService()
/// let stream = try await service.start(
///   prompt: "Hello, Claude!",
///   sessionId: nil,
///   workingDirectory: URL(fileURLWithPath: "/path/to/project")
/// )
///
/// for try await event in stream {
///   switch event {
///   case .assistant(let assistantEvent):
///     // Handle assistant message
///   case .controlRequest(let request):
///     // Handle tool approval
///   default:
///     break
///   }
/// }
/// ```
public actor ClaudeHeadlessService {

  // MARK: - State

  /// The currently running process, if any
  private var currentProcess: Process?

  /// Stdin pipe for sending control responses
  private var stdinPipe: Pipe?

  /// Stdout pipe for reading JSONL events
  private var stdoutPipe: Pipe?

  /// Stderr pipe for capturing error output
  private var stderrPipe: Pipe?

  /// Whether a session is currently active
  private var isSessionActive: Bool = false

  /// The current session ID, if known
  private var currentSessionId: String?

  /// Stream continuation for cancellation
  private var currentContinuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation?

  // MARK: - Constants

  /// Common locations where Claude CLI might be installed
  private static let claudeBinaryPaths = [
    "\(NSHomeDirectory())/.claude/local/claude",
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude"
  ]

  // MARK: - Initialization

  public init() { }

  // MARK: - Public Methods

  /// Starts a headless Claude session.
  ///
  /// - Parameters:
  ///   - prompt: The user prompt to send
  ///   - sessionId: Optional session ID to resume
  ///   - workingDirectory: Working directory for Claude
  /// - Returns: An async stream of Claude events
  /// - Throws: `ClaudeHeadlessError` if the session fails to start
  public func start(
    prompt: String,
    sessionId: String?,
    workingDirectory: URL
  ) async throws -> AsyncThrowingStream<ClaudeEvent, Error> {
    // Stop any existing session first
    await stop()

    AppLogger.session.info("ClaudeHeadlessService.start called with prompt: \(prompt.prefix(50))...")

    // Find the Claude binary
    let claudePath = try findClaudeBinary()
    AppLogger.session.info("Found Claude binary at: \(claudePath)")

    // Build command arguments
    var arguments = [
      "-p", prompt,
      "--output-format", "stream-json",
      "--verbose",
      "--permission-prompt-tool", "stdio",
      "--input-format", "stream-json"
    ]

    // Add resume flag if we have a session ID
    if let sessionId = sessionId {
      arguments.append(contentsOf: ["--resume", sessionId])
      AppLogger.session.info("Resuming session: \(sessionId)")
    }

    // Create pipes
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    // Configure process
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claudePath)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Set environment to prevent interactive prompts
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "dumb"
    process.environment = environment

    // Store references
    self.currentProcess = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
    self.isSessionActive = true
    self.currentSessionId = sessionId

    // Start the process
    do {
      try process.run()
      AppLogger.session.info("Claude process started with PID: \(process.processIdentifier)")
    } catch {
      await cleanupProcess()
      throw ClaudeHeadlessError.processStartFailed(error.localizedDescription)
    }

    // Create the async stream
    let stream = createEventStream(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe
    )

    return stream
  }

  /// Sends a control response for tool approval.
  ///
  /// - Parameters:
  ///   - requestId: The request ID from the control_request event
  ///   - allow: Whether to allow the tool use
  ///   - updatedInput: Optional modified input for the tool
  /// - Throws: `ClaudeHeadlessError` if the response fails to send
  public func sendControlResponse(
    requestId: String,
    allow: Bool,
    updatedInput: [String: Any]? = nil
  ) async throws {
    guard isSessionActive else {
      throw ClaudeHeadlessError.noActiveSession
    }

    guard let stdinPipe = stdinPipe else {
      throw ClaudeHeadlessError.noActiveSession
    }

    AppLogger.session.info("Sending control response for request: \(requestId), allow: \(allow)")

    // Build the control response JSON
    let behavior = allow ? "allow" : "deny"
    let response = ControlResponse(
      response: ControlResponse.ResponsePayload(
        requestId: requestId,
        response: ControlResponse.BehaviorResponse(behavior: behavior)
      )
    )

    do {
      let encoder = JSONEncoder()
      let jsonData = try encoder.encode(response)

      // Write JSON followed by newline
      let fileHandle = stdinPipe.fileHandleForWriting
      fileHandle.write(jsonData)
      fileHandle.write("\n".data(using: .utf8)!)

      AppLogger.session.debug("Control response sent successfully")
    } catch {
      AppLogger.session.error("Failed to encode control response: \(error.localizedDescription)")
      throw ClaudeHeadlessError.stdinWriteFailed(error.localizedDescription)
    }
  }

  /// Stops the current session.
  public func stop() async {
    AppLogger.session.info("ClaudeHeadlessService.stop called")

    // Cancel the stream
    currentContinuation?.finish(throwing: ClaudeHeadlessError.cancelled)
    currentContinuation = nil

    // Terminate the process
    if let process = currentProcess, process.isRunning {
      process.terminate()
      AppLogger.session.info("Terminated Claude process")
    }

    await cleanupProcess()
  }

  // MARK: - Session State

  /// Returns whether a session is currently active.
  public func isActive() async -> Bool {
    isSessionActive
  }

  /// Returns the current session ID, if known.
  public func getSessionId() async -> String? {
    currentSessionId
  }

  // MARK: - Private Methods

  /// Finds the Claude CLI binary in common installation locations.
  private func findClaudeBinary() throws -> String {
    // First check common paths
    for path in Self.claudeBinaryPaths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // Fall back to `which claude`
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = ["claude"]

    let pipe = Pipe()
    whichProcess.standardOutput = pipe
    whichProcess.standardError = FileHandle.nullDevice

    do {
      try whichProcess.run()
      whichProcess.waitUntilExit()

      if whichProcess.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
          return path
        }
      }
    } catch {
      AppLogger.session.warning("which claude failed: \(error.localizedDescription)")
    }

    throw ClaudeHeadlessError.claudeNotFound
  }

  /// Creates an AsyncThrowingStream that parses JSONL from stdout.
  private nonisolated func createEventStream(
    process: Process,
    stdoutPipe: Pipe,
    stderrPipe: Pipe
  ) -> AsyncThrowingStream<ClaudeEvent, Error> {

    return AsyncThrowingStream { continuation in
      // Start a task to read and parse stdout
      Task { [weak self] in
        await self?.setContinuation(continuation)

        let decoder = JSONDecoder()
        var stderrOutput = ""

        // Start stderr reading task
        let stderrTask = Task {
          for try await line in stderrPipe.fileHandleForReading.bytes.lines {
            stderrOutput += line + "\n"
            AppLogger.session.debug("Claude stderr: \(line)")
          }
        }

        do {
          // Read stdout line by line
          for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
            // Skip empty lines
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
              continue
            }

            AppLogger.session.debug("Received JSONL: \(line.prefix(200))...")

            // Parse the JSON line
            guard let data = line.data(using: .utf8) else {
              AppLogger.session.warning("Failed to convert line to data: \(line.prefix(100))")
              continue
            }

            do {
              let event = try decoder.decode(ClaudeEvent.self, from: data)

              // Extract session ID from system init event
              if case .system(let systemEvent) = event,
                 systemEvent.subtype == "init",
                 let sessionId = systemEvent.sessionId {
                await self?.updateSessionId(sessionId)
                AppLogger.session.info("Session ID extracted: \(sessionId)")
              }

              // Check for authentication failure in assistant events
              if case .assistant(let assistantEvent) = event,
                 let error = assistantEvent.error {
                if error == "authentication_failed" {
                  continuation.finish(throwing: ClaudeHeadlessError.authenticationFailed(
                    "Please run `claude /login` in your terminal to authenticate."
                  ))
                  await self?.cleanupProcess()
                  return
                } else {
                  // Other errors - yield them but also log
                  AppLogger.session.error("Claude assistant error: \(error)")
                }
              }

              // Yield the event
              continuation.yield(event)

              // Check if this is a result event (session complete)
              if case .result(let resultEvent) = event {
                if resultEvent.isError == true {
                  let errorMessage = resultEvent.error ?? resultEvent.result ?? "Unknown error"
                  AppLogger.session.error("Claude session ended with error: \(errorMessage)")
                } else {
                  AppLogger.session.info("Claude session completed successfully")
                }
              }

            } catch {
              // Log parse errors but continue processing
              AppLogger.session.warning("Failed to parse JSONL line: \(error.localizedDescription). Line: \(line.prefix(200))")
              // Don't throw - continue processing other lines
            }
          }

          // Wait for process to fully exit
          process.waitUntilExit()

          // Cancel stderr task
          stderrTask.cancel()

          let exitCode = process.terminationStatus
          AppLogger.session.info("Claude process exited with code: \(exitCode)")

          if exitCode != 0 && exitCode != 15 { // 15 = SIGTERM (normal termination)
            // Check stderr for more info
            if !stderrOutput.isEmpty {
              AppLogger.session.error("Claude stderr output: \(stderrOutput)")
            }
            continuation.finish(throwing: ClaudeHeadlessError.processTerminated(exitCode))
          } else {
            continuation.finish()
          }

        } catch {
          AppLogger.session.error("Stream reading error: \(error.localizedDescription)")
          continuation.finish(throwing: error)
        }

        await self?.cleanupProcess()
      }

      // Handle stream cancellation
      continuation.onTermination = { @Sendable termination in
        if case .cancelled = termination {
          AppLogger.session.info("Event stream was cancelled")
          if process.isRunning {
            process.terminate()
          }
        }
      }
    }
  }

  /// Updates the session ID (called from stream task).
  private func updateSessionId(_ sessionId: String) {
    self.currentSessionId = sessionId
  }

  /// Sets the current continuation for cancellation support.
  private func setContinuation(_ continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation) {
    self.currentContinuation = continuation
  }

  /// Cleans up process resources.
  private func cleanupProcess() {
    currentProcess = nil
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
    isSessionActive = false
    currentContinuation = nil
  }
}
