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

  /// Tool approval is not supported in headless mode (stdin is null device)
  case toolApprovalNotSupported

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
    case .toolApprovalNotSupported:
      return "Tool approval is not supported in headless mode. Use --permission-mode acceptEdits."
    }
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

  // MARK: - Configuration

  /// Additional paths to search for Claude binary and include in PATH
  private let additionalPaths: [String]

  // MARK: - State

  /// The currently running process, if any
  private var currentProcess: Process?

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

  /// Default locations where Claude CLI might be installed (in addition to additionalPaths)
  private static var defaultBinaryPaths: [String] {
    let homeDir = NSHomeDirectory()
    return [
      "\(homeDir)/.claude/local",
      "/usr/local/bin",
      "/opt/homebrew/bin",
      "/usr/bin",
      // NVM paths (common Node.js versions)
      "\(homeDir)/.nvm/current/bin",
      "\(homeDir)/.nvm/versions/node/v22.16.0/bin",
      "\(homeDir)/.nvm/versions/node/v20.11.1/bin",
      "\(homeDir)/.nvm/versions/node/v18.19.0/bin"
    ]
  }

  // MARK: - Initialization

  /// Creates a headless service with additional PATH entries.
  /// - Parameter additionalPaths: Additional paths for binary search and PATH enhancement
  public init(additionalPaths: [String] = []) {
    self.additionalPaths = additionalPaths
  }

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
    // Note: --input-format stream-json is intentionally NOT included because it causes
    // Claude to expect JSON on stdin for the initial input, which blocks the process.
    // We use --permission-mode acceptEdits to auto-accept file edits since stdin is null device.
    var arguments = [
      "-p", prompt,
      "--output-format", "stream-json",
      "--verbose",
      "--permission-mode", "acceptEdits"
    ]

    // Add resume flag if we have a session ID
    if let sessionId = sessionId {
      arguments.append(contentsOf: ["--resume", sessionId])
      AppLogger.session.info("Resuming session: \(sessionId)")
    }

    // Create pipes for stdout/stderr
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    // Configure process
    // Note: stdin is set to nullDevice to prevent the CLI from blocking waiting for input.
    // See GitHub issues #7497 and #3187 - using a Pipe() for stdin causes hangs.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claudePath)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Set environment with enhanced PATH
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "dumb"

    // Enhance PATH with additional paths (matching EmbeddedTerminalView pattern)
    let paths = additionalPaths + Self.defaultBinaryPaths
    let pathString = paths.joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }

    process.environment = environment

    // Store references
    self.currentProcess = process
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
  /// - Note: Tool approval via stdin is not supported in headless mode because
  ///   stdin is set to nullDevice to prevent blocking. Use `--permission-mode acceptEdits`
  ///   for auto-accepting edits, or implement PTY-based interaction for full control.
  ///
  /// - Parameters:
  ///   - requestId: The request ID from the control_request event
  ///   - allow: Whether to allow the tool use
  ///   - updatedInput: Optional modified input for the tool
  /// - Throws: `ClaudeHeadlessError.toolApprovalNotSupported` always
  public func sendControlResponse(
    requestId: String,
    allow: Bool,
    updatedInput: [String: Any]? = nil
  ) async throws {
    // Tool approval via stdin is not supported in headless mode.
    // The process uses FileHandle.nullDevice for stdin to prevent blocking.
    // Use --permission-mode acceptEdits for auto-accepting file edits.
    throw ClaudeHeadlessError.toolApprovalNotSupported
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
  ///
  /// Search order:
  /// 1. Additional paths from configuration (highest priority)
  /// 2. Default binary paths (includes NVM paths)
  /// 3. Fall back to `which claude`
  private func findClaudeBinary() throws -> String {
    let fileManager = FileManager.default

    // Combine additional paths (priority) with default paths
    let allPaths = additionalPaths + Self.defaultBinaryPaths

    // Search for claude binary in all paths
    for basePath in allPaths {
      let fullPath = "\(basePath)/claude"
      if fileManager.isExecutableFile(atPath: fullPath) {
        AppLogger.session.debug("Found Claude binary at: \(fullPath)")
        return fullPath
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
  /// Uses readabilityHandler (callback-based) for reliable pipe reading.
  private nonisolated func createEventStream(
    process: Process,
    stdoutPipe: Pipe,
    stderrPipe: Pipe
  ) -> AsyncThrowingStream<ClaudeEvent, Error> {

    return AsyncThrowingStream { continuation in
      let decoder = JSONDecoder()
      var stdoutBuffer = ""
      var stderrOutput = ""

      // Use readabilityHandler for stdout - this is more reliable than bytes.lines for subprocess pipes
      stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData

        if data.isEmpty {
          // EOF - process has closed stdout
          AppLogger.session.info("Claude stdout EOF reached")
          return
        }

        guard let text = String(data: data, encoding: .utf8) else {
          AppLogger.session.warning("Failed to decode stdout data as UTF-8")
          return
        }

        AppLogger.session.debug("Received stdout chunk: \(text.prefix(100))...")

        // Append to buffer and process complete lines
        stdoutBuffer += text
        let lines = stdoutBuffer.components(separatedBy: "\n")

        // Process all complete lines (everything except the last element which may be incomplete)
        for i in 0..<(lines.count - 1) {
          let line = lines[i].trimmingCharacters(in: .whitespaces)
          guard !line.isEmpty else { continue }

          AppLogger.session.debug("Received JSONL: \(line.prefix(200))...")

          guard let jsonData = line.data(using: .utf8) else {
            AppLogger.session.warning("Failed to convert line to data: \(line.prefix(100))")
            continue
          }

          do {
            let event = try decoder.decode(ClaudeEvent.self, from: jsonData)

            // Extract session ID from system init event
            if case .system(let systemEvent) = event,
               systemEvent.subtype == "init",
               let sessionId = systemEvent.sessionId {
              Task {
                await self?.updateSessionId(sessionId)
              }
              AppLogger.session.info("Session ID extracted: \(sessionId)")
            }

            // Check for authentication failure in assistant events
            if case .assistant(let assistantEvent) = event,
               let error = assistantEvent.error {
              if error == "authentication_failed" {
                continuation.finish(throwing: ClaudeHeadlessError.authenticationFailed(
                  "Please run `claude /login` in your terminal to authenticate."
                ))
                Task {
                  await self?.cleanupProcess()
                }
                return
              } else {
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
            AppLogger.session.warning("Failed to parse JSONL line: \(error.localizedDescription). Line: \(line.prefix(200))")
          }
        }

        // Keep the last incomplete line in the buffer
        stdoutBuffer = lines.last ?? ""
      }

      // Handle stderr
      stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
          stderrOutput += text
          AppLogger.session.debug("Claude stderr: \(text)")
        }
      }

      // Handle process termination
      process.terminationHandler = { [weak self] proc in
        // Clean up handlers
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let exitCode = proc.terminationStatus
        AppLogger.session.info("Claude process exited with code: \(exitCode)")

        if exitCode != 0 && exitCode != 15 { // 15 = SIGTERM (normal termination)
          if !stderrOutput.isEmpty {
            AppLogger.session.error("Claude stderr output: \(stderrOutput)")
          }
          continuation.finish(throwing: ClaudeHeadlessError.processTerminated(exitCode))
        } else {
          continuation.finish()
        }

        Task {
          await self?.cleanupProcess()
        }
      }

      // Store continuation for cancellation support
      Task { [weak self] in
        await self?.setContinuation(continuation)
      }

      // Handle stream cancellation
      continuation.onTermination = { @Sendable termination in
        if case .cancelled = termination {
          AppLogger.session.info("Event stream was cancelled")
          stdoutPipe.fileHandleForReading.readabilityHandler = nil
          stderrPipe.fileHandleForReading.readabilityHandler = nil
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
    stdoutPipe = nil
    stderrPipe = nil
    isSessionActive = false
    currentContinuation = nil
  }
}
