//
//  MCPStdioJSONRPCClient.swift
//  AgentHub
//

import AgentHubMCPUI
import Darwin
import Foundation

public final class MCPStdioJSONRPCClient: MCPJSONRPCClientProtocol, @unchecked Sendable {
  private let config: MCPServerConfiguration
  private let requestTimeoutSeconds: TimeInterval
  private let process = Process()
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let readQueue = DispatchQueue(label: "com.agenthub.mcp-stdio.read")
  private let writeQueue = DispatchQueue(label: "com.agenthub.mcp-stdio.write")
  private let lifecycleLock = NSLock()
  private var nextID = 1
  private var isClosed = false

  public init(config: MCPServerConfiguration, requestTimeoutSeconds: TimeInterval) {
    self.config = config
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }

  public func start() throws {
    guard let command = config.command, !command.isEmpty else {
      throw MCPAppDiscoveryError.processLaunchFailed("Missing stdio command for \(config.name).")
    }

    if command.hasPrefix("/") {
      process.executableURL = URL(fileURLWithPath: command)
      process.arguments = config.args
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [command] + config.args
    }

    let cwd = config.cwd ?? config.projectPath
    if !cwd.isEmpty {
      process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }

    process.environment = ProcessInfo.processInfo.environment.merging(config.env) { _, new in new }
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }

    do {
      try process.run()
    } catch {
      throw MCPAppDiscoveryError.processLaunchFailed(error.localizedDescription)
    }
  }

  public func request(
    method: String,
    params: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    let id = nextRequestID()
    let envelope = MCPJSONRPCMessage.requestEnvelope(id: id, method: method, params: params)
    try write(envelope)

    return try await withTimeout(method: method) {
      while true {
        let line = try await self.readLine()
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AgentHubMCPUIJSONValue.self, from: data),
              decoded.objectValue != nil else {
          throw MCPAppDiscoveryError.invalidResponse(line)
        }

        guard let result = try MCPJSONRPCMessage.result(
          from: decoded,
          expectedID: id,
          method: method
        ) else {
          continue
        }
        return result
      }
    }
  }

  public func notify(method: String, params: AgentHubMCPUIJSONValue?) async throws {
    let envelope = MCPJSONRPCMessage.notificationEnvelope(method: method, params: params)
    try write(envelope)
  }

  public func close() {
    lifecycleLock.lock()
    guard !isClosed else {
      lifecycleLock.unlock()
      return
    }
    isClosed = true
    lifecycleLock.unlock()

    stderrPipe.fileHandleForReading.readabilityHandler = nil
    try? stdinPipe.fileHandleForWriting.close()
    try? stdoutPipe.fileHandleForReading.close()
    try? stderrPipe.fileHandleForReading.close()

    guard process.isRunning else { return }
    process.terminate()

    let process = process
    let processID = process.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
      if process.isRunning {
        kill(processID, SIGKILL)
      }
    }
  }

  private func nextRequestID() -> Int {
    writeQueue.sync {
      let id = nextID
      nextID += 1
      return id
    }
  }

  private func write(_ value: AgentHubMCPUIJSONValue) throws {
    let data = try JSONEncoder().encode(value)
    writeQueue.sync {
      stdinPipe.fileHandleForWriting.write(data)
      stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }
  }

  private func readLine() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      readQueue.async {
        var data = Data()
        while true {
          let byte = self.stdoutPipe.fileHandleForReading.readData(ofLength: 1)
          if byte.isEmpty {
            continuation.resume(throwing: MCPAppDiscoveryError.processClosed(self.config.name))
            return
          }
          if byte == Data([0x0A]) {
            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            return
          }
          data.append(byte)
        }
      }
    }
  }

  private func withTimeout<T: Sendable>(
    method: String,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(self.requestTimeoutSeconds))
        throw MCPAppDiscoveryError.requestTimedOut(method)
      }

      do {
        guard let value = try await group.next() else {
          throw MCPAppDiscoveryError.requestTimedOut(method)
        }
        group.cancelAll()
        return value
      } catch {
        close()
        group.cancelAll()
        throw error
      }
    }
  }
}
