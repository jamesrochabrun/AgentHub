//
//  ClaudeCLIClient.swift
//  ClaudeCodeClient
//

import Combine
import Foundation

public protocol ClaudeCLIClientProtocol: Sendable {
  func runStreamingPrompt(
    prompt: String,
    workingDirectory: String,
    systemPrompt: String?,
    permissionMode: String?,
    disallowedTools: [String]?
  ) -> AnyPublisher<StreamJSONChunk, Error>

  @MainActor func cancel()
}

public final class ClaudeCLIClient: ClaudeCLIClientProtocol, @unchecked Sendable {

  private let command: String
  private let additionalPaths: [String]
  private let debugLogger: (@Sendable (String) -> Void)?

  private var runningProcess: Process?
  private let lock = NSLock()

  public init(
    command: String = "claude",
    additionalPaths: [String] = [],
    debugLogger: (@Sendable (String) -> Void)? = nil
  ) {
    self.command = command
    self.additionalPaths = additionalPaths
    self.debugLogger = debugLogger
  }

  public func runStreamingPrompt(
    prompt: String,
    workingDirectory: String,
    systemPrompt: String?,
    permissionMode: String?,
    disallowedTools: [String]?
  ) -> AnyPublisher<StreamJSONChunk, Error> {
    let parsedCommand = ParsedCommand(command: command)

    guard let executablePath = ClaudeCLIExecutableResolver.findExecutable(
      command: parsedCommand.executableName,
      additionalPaths: additionalPaths
    ) else {
      return Fail(error: ClaudeCodeClientError.notInstalled(parsedCommand.executableName))
        .eraseToAnyPublisher()
    }

    let subject = PassthroughSubject<StreamJSONChunk, Error>()
    let decoder = JSONDecoder()
    let allPaths = ClaudeCLIExecutableResolver.searchPaths(additionalPaths: additionalPaths)

    var args = parsedCommand.prefixArguments + ["-p", "--output-format", "stream-json", "--verbose"]

    if let permissionMode, !permissionMode.isEmpty {
      args += ["--permission-mode", permissionMode]
    }

    if let systemPrompt, !systemPrompt.isEmpty {
      args += ["--system-prompt", systemPrompt]
    }

    if let disallowedTools, !disallowedTools.isEmpty {
      args += ["--disallowed-tools", disallowedTools.joined(separator: ",")]
    }

    Task.detached { [weak self] in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = args

      if !workingDirectory.isEmpty {
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
      }

      var environment = ProcessInfo.processInfo.environment
      if !allPaths.isEmpty {
        let joinedPaths = allPaths.joined(separator: ":")
        if let existingPath = environment["PATH"] {
          environment["PATH"] = "\(joinedPaths):\(existingPath)"
        } else {
          environment["PATH"] = joinedPaths
        }
      }
      process.environment = environment

      let stdinPipe = Pipe()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardInput = stdinPipe
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      self?.setRunningProcess(process)

      var lineBuffer = Data()

      stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }

        lineBuffer.append(data)

        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
          lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])

          guard !lineData.isEmpty else { continue }

          do {
            let chunk = try decoder.decode(StreamJSONChunk.self, from: Data(lineData))
            subject.send(chunk)
          } catch {
            let rawLine = String(data: Data(lineData), encoding: .utf8) ?? "<binary>"
            self?.debugLogger?("Failed to parse stream-json line: \(rawLine) — \(error)")
          }
        }
      }

      var stderrData = Data()
      stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty {
          stderrData.append(data)
        }
      }

      process.terminationHandler = { [weak self] proc in
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        self?.setRunningProcess(nil)

        if !lineBuffer.isEmpty {
          do {
            let chunk = try decoder.decode(StreamJSONChunk.self, from: lineBuffer)
            subject.send(chunk)
          } catch {
            self?.debugLogger?("Discarded trailing partial stream-json line: \(error)")
          }
        }

        if proc.terminationStatus != 0 && proc.terminationReason != .uncaughtSignal {
          let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let message = stderr.isEmpty ? "Process exited with status \(proc.terminationStatus)" : stderr
          subject.send(completion: .failure(ClaudeCodeClientError.executionFailed(message)))
        } else {
          subject.send(completion: .finished)
        }
      }

      do {
        try process.run()
        if let promptData = prompt.data(using: .utf8) {
          stdinPipe.fileHandleForWriting.write(promptData)
        }
        stdinPipe.fileHandleForWriting.closeFile()
      } catch {
        self?.setRunningProcess(nil)
        subject.send(completion: .failure(ClaudeCodeClientError.executionFailed(error.localizedDescription)))
      }
    }

    return subject
      .handleEvents(receiveCancel: { [weak self] in
        Task { @MainActor in
          self?.cancel()
        }
      })
      .eraseToAnyPublisher()
  }

  @MainActor
  public func cancel() {
    lock.lock()
    let process = runningProcess
    runningProcess = nil
    lock.unlock()
    process?.terminate()
  }

  private func setRunningProcess(_ process: Process?) {
    lock.lock()
    runningProcess = process
    lock.unlock()
  }
}

private struct ParsedCommand: Sendable {
  let executableName: String
  let prefixArguments: [String]

  init(command: String) {
    let parts = command.split(separator: " ", omittingEmptySubsequences: true)
    self.executableName = parts.first.map(String.init) ?? command
    self.prefixArguments = parts.dropFirst().map(String.init)
  }
}

private enum ClaudeCLIExecutableResolver {

  static func searchPaths(
    additionalPaths: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    var combinedPaths = ClaudeCodePathResolver.searchPaths(
      additionalPaths: additionalPaths,
      homeDirectory: homeDirectory
    )

    if let environmentPath = environment["PATH"] {
      combinedPaths.append(contentsOf: environmentPath.split(separator: ":").map(String.init))
    }

    return uniquePaths(combinedPaths)
  }

  static func findExecutable(
    command: String,
    additionalPaths: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory()
  ) -> String? {
    let fileManager = FileManager.default

    if command.contains("/") && fileManager.isExecutableFile(atPath: command) {
      return command
    }

    for path in searchPaths(
      additionalPaths: additionalPaths,
      environment: environment,
      homeDirectory: homeDirectory
    ) {
      let fullPath = "\(path)/\(command)"
      if fileManager.isExecutableFile(atPath: fullPath) {
        return fullPath
      }
    }

    return nil
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }
}
