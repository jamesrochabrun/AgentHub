//
//  CLIProcessService.swift
//  AgentHub
//
//  Lightweight service that spawns `claude -p --output-format stream-json`
//  and streams parsed JSON chunks. Replaces ClaudeCodeSDK dependency.
//

import Foundation
import Combine

// MARK: - Protocol

public protocol CLIProcessServiceProtocol: Sendable {
  /// Runs a streaming prompt and returns a publisher of parsed JSON chunks.
  func runStreamingPrompt(
    prompt: String,
    workingDirectory: String,
    systemPrompt: String?,
    permissionMode: String?,
    disallowedTools: [String]?
  ) -> AnyPublisher<StreamJSONChunk, Error>

  /// Cancels the currently running process.
  @MainActor func cancel()
}

// MARK: - Implementation

/// Actor-based service that spawns the Claude CLI process and parses stream-json output.
final class CLIProcessService: CLIProcessServiceProtocol, @unchecked Sendable {

  private let command: String
  private let additionalPaths: [String]
  private let debugLogging: Bool

  /// The running process (accessed only from detached tasks + cancellation).
  private var runningProcess: Process?
  private let lock = NSLock()

  init(
    command: String = "claude",
    additionalPaths: [String] = [],
    debugLogging: Bool = false
  ) {
    self.command = command
    self.additionalPaths = additionalPaths
    self.debugLogging = debugLogging
  }

  convenience init(configuration: CLICommandConfiguration) {
    self.init(
      command: configuration.executableName,
      additionalPaths: configuration.additionalPaths
    )
  }

  func runStreamingPrompt(
    prompt: String,
    workingDirectory: String,
    systemPrompt: String?,
    permissionMode: String?,
    disallowedTools: [String]?
  ) -> AnyPublisher<StreamJSONChunk, Error> {
    let subject = PassthroughSubject<StreamJSONChunk, Error>()

    // Find executable
    guard let executablePath = TerminalLauncher.findExecutable(
      command: command,
      additionalPaths: additionalPaths
    ) else {
      subject.send(completion: .failure(CLIProcessError.notInstalled(command)))
      return subject.eraseToAnyPublisher()
    }

    // Build arguments
    var args = ["-p", "--output-format", "stream-json", "--verbose"]

    if let permissionMode, !permissionMode.isEmpty {
      args += ["--permission-mode", permissionMode]
    }

    if let systemPrompt, !systemPrompt.isEmpty {
      args += ["--system-prompt", systemPrompt]
    }

    if let disallowedTools, !disallowedTools.isEmpty {
      args += ["--disallowed-tools", disallowedTools.joined(separator: ",")]
    }

    let decoder = JSONDecoder()

    Task.detached { [weak self] in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = args

      if !workingDirectory.isEmpty {
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
      }

      // Set up environment with PATH
      var environment = ProcessInfo.processInfo.environment
      let allPaths = (self?.additionalPaths ?? [])
      if !allPaths.isEmpty {
        let joined = allPaths.joined(separator: ":")
        if let existing = environment["PATH"] {
          environment["PATH"] = "\(joined):\(existing)"
        } else {
          environment["PATH"] = joined
        }
      }
      process.environment = environment

      // Pipes
      let stdinPipe = Pipe()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardInput = stdinPipe
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      // Track the process for cancellation
      self?.lock.lock()
      self?.runningProcess = process
      self?.lock.unlock()

      // Line buffer for partial reads
      var lineBuffer = Data()

      // Handle stdout — parse JSON lines
      stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }

        lineBuffer.append(data)

        // Process complete lines
        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
          lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])

          guard !lineData.isEmpty else { continue }

          do {
            let chunk = try decoder.decode(StreamJSONChunk.self, from: Data(lineData))
            subject.send(chunk)
          } catch {
            if self?.debugLogging == true {
              let raw = String(data: Data(lineData), encoding: .utf8) ?? "<binary>"
              AppLogger.intelligence.debug("Failed to parse stream-json line: \(raw) — \(error)")
            }
          }
        }
      }

      // Collect stderr for error reporting
      var stderrData = Data()
      stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty {
          stderrData.append(data)
        }
      }

      // Termination handler
      process.terminationHandler = { [weak self] proc in
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        self?.lock.lock()
        self?.runningProcess = nil
        self?.lock.unlock()

        // Process any remaining data in the line buffer
        if !lineBuffer.isEmpty {
          do {
            let chunk = try decoder.decode(StreamJSONChunk.self, from: lineBuffer)
            subject.send(chunk)
          } catch {
            // Ignore trailing partial data
          }
        }

        if proc.terminationStatus != 0 && proc.terminationReason != .uncaughtSignal {
          let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let message = stderr.isEmpty ? "Process exited with status \(proc.terminationStatus)" : stderr
          subject.send(completion: .failure(CLIProcessError.executionFailed(message)))
        } else {
          subject.send(completion: .finished)
        }
      }

      do {
        try process.run()

        // Send prompt via stdin and close
        if let promptData = prompt.data(using: .utf8) {
          stdinPipe.fileHandleForWriting.write(promptData)
        }
        stdinPipe.fileHandleForWriting.closeFile()
      } catch {
        self?.lock.lock()
        self?.runningProcess = nil
        self?.lock.unlock()
        subject.send(completion: .failure(CLIProcessError.executionFailed(error.localizedDescription)))
      }
    }

    return subject.eraseToAnyPublisher()
  }

  @MainActor
  func cancel() {
    lock.lock()
    let process = runningProcess
    runningProcess = nil
    lock.unlock()
    process?.terminate()
  }
}
