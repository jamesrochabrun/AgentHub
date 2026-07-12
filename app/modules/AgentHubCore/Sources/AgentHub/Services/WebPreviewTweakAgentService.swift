//
//  WebPreviewTweakAgentService.swift
//  AgentHub
//

import Foundation

protocol WebPreviewTweakAgentRunning: Sendable {
  func runTweakAgent(
    prompt: String,
    targetFileURL: URL,
    policy: InspectorTweakPolicy,
    cliConfiguration: CLICommandConfiguration
  ) async throws -> InspectorTweakResult
}

protocol TweakAgentCommandRunning: Sendable {
  func run(
    prompt: String,
    systemPrompt: String,
    workingDirectory: String,
    cliConfiguration: CLICommandConfiguration
  ) async throws
}

enum WebPreviewTweakAgentError: LocalizedError {
  case timedOut
  case executableNotFound(String)
  case commandFailed(Int32)

  var errorDescription: String? {
    switch self {
    case .timedOut:
      return "The tweak agent did not finish within three minutes."
    case .executableNotFound(let command):
      return "Could not find the configured \(command) command."
    case .commandFailed(let status):
      return "The tweak agent exited with status \(status)."
    }
  }
}

actor WebPreviewTweakAgentService: WebPreviewTweakAgentRunning {
  static let systemPrompt = """
    You are a focused background editor inside AgentHub. Complete the requested tweak controls by editing the single design file in the working directory.

    Rules:
    - Edit only that file.
    - Do not start a server, run a browser, create supporting files, or inspect parent directories.
    - Preserve the existing design and behavior outside the requested tweak controls.
    - Treat existing tweak controls as cumulative project state. Read and understand the current dc_set_props declaration and render behavior before editing; preserve every existing control unless the user explicitly asks to change or remove it.
    - When asked for more ideas, add only controls that are distinct in both name and behavior. Extend the existing declaration and render function instead of replacing them.
    - Do not stop to explain or ask questions. Make the edit, verify the contract in the prompt, and finish.
    """

  private let workspaceCoordinator: any TweakWorkspaceCoordinating
  private let commandRunner: any TweakAgentCommandRunning
  private let timeout: Duration

  init(
    workspaceCoordinator: any TweakWorkspaceCoordinating = TweakWorkspaceCoordinator(),
    commandRunner: any TweakAgentCommandRunning = TweakAgentProcessRunner(),
    timeout: Duration = .seconds(180)
  ) {
    self.workspaceCoordinator = workspaceCoordinator
    self.commandRunner = commandRunner
    self.timeout = timeout
  }

  func runTweakAgent(
    prompt: String,
    targetFileURL: URL,
    policy: InspectorTweakPolicy,
    cliConfiguration: CLICommandConfiguration
  ) async throws -> InspectorTweakResult {
    let transaction = try await workspaceCoordinator.prepare(targetFileURL: targetFileURL)

    do {
      try await runCommandWithTimeout(
        prompt: prompt,
        workingDirectory: transaction.rootURL.path,
        cliConfiguration: cliConfiguration
      )
      return try await workspaceCoordinator.finish(transaction, policy: policy)
    } catch {
      await workspaceCoordinator.discard(transaction)
      throw error
    }
  }

  private func runCommandWithTimeout(
    prompt: String,
    workingDirectory: String,
    cliConfiguration: CLICommandConfiguration
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [commandRunner] in
        try await commandRunner.run(
          prompt: prompt,
          systemPrompt: Self.systemPrompt,
          workingDirectory: workingDirectory,
          cliConfiguration: cliConfiguration
        )
      }
      group.addTask { [timeout] in
        try await Task.sleep(for: timeout)
        throw WebPreviewTweakAgentError.timedOut
      }

      _ = try await group.next()
      group.cancelAll()
    }
  }
}

final class TweakAgentProcessRunner: TweakAgentCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var runningProcess: Process?

  func run(
    prompt: String,
    systemPrompt: String,
    workingDirectory: String,
    cliConfiguration: CLICommandConfiguration
  ) async throws {
    let executablePath: String?
    switch cliConfiguration.mode {
    case .claude:
      executablePath = TerminalLauncher.findClaudeExecutable(
        command: cliConfiguration.executableName,
        additionalPaths: cliConfiguration.additionalPaths
      )
    case .codex:
      executablePath = TerminalLauncher.findCodexExecutable(
        command: cliConfiguration.executableName,
        additionalPaths: cliConfiguration.additionalPaths
      )
    }
    guard let executablePath else {
      throw WebPreviewTweakAgentError.executableNotFound(cliConfiguration.executableName)
    }

    let arguments = Self.arguments(
      prompt: prompt,
      systemPrompt: systemPrompt,
      workingDirectory: workingDirectory,
      cliConfiguration: cliConfiguration
    )

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        let paths = CLIPathResolver.executableSearchPaths(
          additionalPaths: cliConfiguration.additionalPaths
        ).joined(separator: ":")
        if !paths.isEmpty {
          environment["PATH"] = [paths, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        }
        environment.merge(CLIEnvironmentOverrides.environment) { _, new in new }
        process.environment = environment

        process.terminationHandler = { [weak self] process in
          self?.setRunningProcess(nil)
          if process.terminationReason == .exit, process.terminationStatus == 0 {
            continuation.resume()
          } else {
            continuation.resume(throwing: WebPreviewTweakAgentError.commandFailed(process.terminationStatus))
          }
        }

        do {
          setRunningProcess(process)
          try process.run()
        } catch {
          setRunningProcess(nil)
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  static func arguments(
    prompt: String,
    systemPrompt: String,
    workingDirectory: String,
    cliConfiguration: CLICommandConfiguration
  ) -> [String] {
    let prefix = cliConfiguration.subcommandArgs + cliConfiguration.extraArgs
    switch cliConfiguration.mode {
    case .claude:
      return prefix + [
        "-p",
        "--no-session-persistence",
        "--permission-mode", "acceptEdits",
        "--append-system-prompt", systemPrompt,
        prompt
      ]
    case .codex:
      return prefix + [
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--sandbox", "workspace-write",
        "--cd", workingDirectory,
        "\(systemPrompt)\n\nTask:\n\(prompt)"
      ]
    }
  }

  private func cancel() {
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
