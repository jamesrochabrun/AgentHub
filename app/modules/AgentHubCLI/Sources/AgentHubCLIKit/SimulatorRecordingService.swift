import Darwin
import Foundation

public struct SimulatorRecordingStarted: Codable, Equatable, Sendable {
  public let udid: String
  public let outputPath: String
  public let startedAt: Date

  public init(udid: String, outputPath: String, startedAt: Date) {
    self.udid = udid
    self.outputPath = outputPath
    self.startedAt = startedAt
  }
}

public struct SimulatorRecordingResult: Codable, Equatable, Sendable {
  public let udid: String
  public let outputPath: String
  public let startedAt: Date
  public let endedAt: Date
  public let duration: TimeInterval
  public let fileExists: Bool
  public let fileSizeBytes: Int64?
  public let isFinalized: Bool
  public let validationError: String?

  public var isUsable: Bool {
    fileExists && (fileSizeBytes ?? 0) > 0 && isFinalized && validationError == nil
  }

  public init(
    udid: String,
    outputPath: String,
    startedAt: Date,
    endedAt: Date,
    duration: TimeInterval,
    fileExists: Bool,
    fileSizeBytes: Int64?,
    isFinalized: Bool,
    validationError: String?
  ) {
    self.udid = udid
    self.outputPath = outputPath
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.duration = duration
    self.fileExists = fileExists
    self.fileSizeBytes = fileSizeBytes
    self.isFinalized = isFinalized
    self.validationError = validationError
  }
}

public enum SimulatorRecordingError: LocalizedError, Equatable, Sendable {
  case xcrunNotFound
  case alreadyRecording(String)
  case notRecording(String)
  case invalidFileName(String)
  case startFailed(String)

  public var errorDescription: String? {
    switch self {
    case .xcrunNotFound:
      return "xcrun not found in PATH."
    case .alreadyRecording(let udid):
      return "Simulator \(udid) is already recording."
    case .notRecording(let udid):
      return "Simulator \(udid) is not recording."
    case .invalidFileName(let fileName):
      return "Invalid recording file name: \(fileName)"
    case .startFailed(let detail):
      return "Could not start simulator recording: \(detail)"
    }
  }
}

public protocol SimulatorRecordingProcess: AnyObject, Sendable {
  var isRunning: Bool { get }
  var terminationStatus: Int32 { get }
  var diagnosticOutput: String { get }
  func interrupt()
  func terminate()
  func waitUntilExit()
}

public protocol SimulatorRecordingProcessRunning: Sendable {
  func start(arguments: [String]) throws -> any SimulatorRecordingProcess
}

public final class SimulatorRecordingProcessRef: SimulatorRecordingProcess, @unchecked Sendable {
  private let process: Process
  private let diagnosticURL: URL

  public init(process: Process, diagnosticURL: URL) {
    self.process = process
    self.diagnosticURL = diagnosticURL
  }

  deinit {
    try? FileManager.default.removeItem(at: diagnosticURL)
  }

  public var isRunning: Bool { process.isRunning }
  public var terminationStatus: Int32 { process.terminationStatus }
  public var diagnosticOutput: String {
    guard let data = try? Data(contentsOf: diagnosticURL),
          let output = String(data: data, encoding: .utf8) else {
      return ""
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func interrupt() {
    signalProcessTree(SIGINT)
  }

  public func terminate() {
    signalProcessTree(SIGTERM)
  }

  public func waitUntilExit() {
    process.waitUntilExit()
  }

  private func signalProcessTree(_ signal: Int32) {
    let pid = process.processIdentifier
    for childPID in Self.descendantPIDs(of: pid).reversed() {
      _ = kill(childPID, signal)
    }
    _ = kill(pid, signal)
  }

  private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
    var descendants: [pid_t] = []
    var stack = childPIDs(of: rootPID)

    while let pid = stack.popLast() {
      descendants.append(pid)
      stack.append(contentsOf: childPIDs(of: pid))
    }

    return descendants
  }

  private static func childPIDs(of pid: pid_t) -> [pid_t] {
    let childCount = proc_listchildpids(pid, nil, 0)
    guard childCount > 0 else { return [] }

    var pids = [pid_t](repeating: 0, count: Int(childCount))
    let byteCount = Int32(pids.count * MemoryLayout<pid_t>.size)
    let result = pids.withUnsafeMutableBytes { buffer in
      proc_listchildpids(pid, buffer.baseAddress, byteCount)
    }

    guard result > 0 else { return [] }
    return Array(pids.prefix(Int(result))).filter { $0 > 0 }
  }
}

public struct SimulatorRecordingProcessRunner: SimulatorRecordingProcessRunning {
  public init() {}

  public func start(arguments: [String]) throws -> any SimulatorRecordingProcess {
    guard let xcrun = Self.findExecutable(named: "xcrun") else {
      throw SimulatorRecordingError.xcrunNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = arguments
    process.standardOutput = Pipe()
    let diagnosticURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-simulator-recording-\(UUID().uuidString).stderr")
    FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil)
    let diagnosticHandle = try FileHandle(forWritingTo: diagnosticURL)
    process.standardError = diagnosticHandle
    try process.run()
    try? diagnosticHandle.close()
    return SimulatorRecordingProcessRef(process: process, diagnosticURL: diagnosticURL)
  }

  private static func findExecutable(named name: String) -> String? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      .split(separator: ":")
      .map(String.init)
    for path in paths {
      let candidate = (path as NSString).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}

public actor SimulatorRecordingService {
  public static let shared = SimulatorRecordingService()

  private struct ActiveRecording {
    let process: any SimulatorRecordingProcess
    let started: SimulatorRecordingStarted
  }

  private struct ProcessStopResult {
    let wasForced: Bool
    let exited: Bool
    let diagnosticOutput: String
  }

  private let runner: any SimulatorRecordingProcessRunning
  private let dateProvider: @Sendable () -> Date
  private let startConfirmationTimeout: Duration
  private let gracefulStopTimeout: Duration
  private let forcedStopTimeout: Duration
  private let finalizationTimeout: Duration
  private let pollingInterval: Duration
  private var activeRecordings: [String: ActiveRecording] = [:]

  public init(
    runner: any SimulatorRecordingProcessRunning = SimulatorRecordingProcessRunner(),
    dateProvider: @escaping @Sendable () -> Date = { Date() },
    startConfirmationTimeout: Duration = .seconds(5),
    gracefulStopTimeout: Duration = .seconds(15),
    forcedStopTimeout: Duration = .seconds(2),
    finalizationTimeout: Duration = .seconds(10),
    pollingInterval: Duration = .milliseconds(100)
  ) {
    self.runner = runner
    self.dateProvider = dateProvider
    self.startConfirmationTimeout = startConfirmationTimeout
    self.gracefulStopTimeout = gracefulStopTimeout
    self.forcedStopTimeout = forcedStopTimeout
    self.finalizationTimeout = finalizationTimeout
    self.pollingInterval = pollingInterval
  }

  public func startRecording(
    udid: String,
    outputDirectory: URL? = nil,
    fileName: String? = nil
  ) async throws -> SimulatorRecordingStarted {
    if let active = activeRecordings[udid], active.process.isRunning {
      throw SimulatorRecordingError.alreadyRecording(udid)
    }
    activeRecordings.removeValue(forKey: udid)

    let directory = outputDirectory ?? Self.defaultRecordingsDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let startedAt = dateProvider()
    let outputURL = directory.appendingPathComponent(
      try Self.recordingFileName(udid: udid, startedAt: startedAt, requestedFileName: fileName),
      isDirectory: false
    )
    let process = try runner.start(arguments: [
      "simctl", "io", udid, "recordVideo", "--force", outputURL.path
    ])

    guard await waitForRecordingStart(process) else {
      activeRecordings.removeValue(forKey: udid)
      try? Self.deleteRecordingFile(at: outputURL.path)
      let detail = Self.shortDiagnostic(process.diagnosticOutput)
      throw SimulatorRecordingError.startFailed(
        detail.isEmpty ? "recordVideo exited before recording started" : detail
      )
    }

    let started = SimulatorRecordingStarted(
      udid: udid,
      outputPath: outputURL.path,
      startedAt: startedAt
    )
    activeRecordings[udid] = ActiveRecording(process: process, started: started)
    return started
  }

  public func stopRecording(udid: String) async throws -> SimulatorRecordingResult {
    guard let active = activeRecordings.removeValue(forKey: udid) else {
      throw SimulatorRecordingError.notRecording(udid)
    }

    let stopResult = await stopProcess(active.process)
    let endedAt = dateProvider()
    let fileURL = URL(fileURLWithPath: active.started.outputPath)
    let validation = await waitForFinalizedMovie(at: fileURL)

    return SimulatorRecordingResult(
      udid: udid,
      outputPath: active.started.outputPath,
      startedAt: active.started.startedAt,
      endedAt: endedAt,
      duration: max(0, endedAt.timeIntervalSince(active.started.startedAt)),
      fileExists: validation.fileExists,
      fileSizeBytes: validation.fileSizeBytes,
      isFinalized: validation.isFinalized,
      validationError: validationError(from: validation, stopResult: stopResult)
    )
  }

  @discardableResult
  public func discardRecording(udid: String) async throws -> SimulatorRecordingResult {
    let result = try await stopRecording(udid: udid)
    try Self.deleteRecordingFile(at: result.outputPath)
    return result
  }

  public func activeRecording(udid: String) -> SimulatorRecordingStarted? {
    guard let active = activeRecordings[udid], active.process.isRunning else {
      activeRecordings.removeValue(forKey: udid)
      return nil
    }
    return active.started
  }

  private func stopProcess(_ process: any SimulatorRecordingProcess) async -> ProcessStopResult {
    guard process.isRunning else {
      process.waitUntilExit()
      return ProcessStopResult(
        wasForced: false,
        exited: true,
        diagnosticOutput: process.diagnosticOutput
      )
    }

    process.interrupt()
    if await waitForProcessExit(process, timeout: gracefulStopTimeout) {
      process.waitUntilExit()
      return ProcessStopResult(
        wasForced: false,
        exited: true,
        diagnosticOutput: process.diagnosticOutput
      )
    }

    process.terminate()
    let exited = await waitForProcessExit(process, timeout: forcedStopTimeout)
    if exited {
      process.waitUntilExit()
    }
    return ProcessStopResult(
      wasForced: true,
      exited: exited,
      diagnosticOutput: process.diagnosticOutput
    )
  }

  private func waitForRecordingStart(_ process: any SimulatorRecordingProcess) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: startConfirmationTimeout)

    while clock.now < deadline {
      if process.diagnosticOutput.contains("Recording started") {
        return true
      }
      if !process.isRunning {
        process.waitUntilExit()
        return false
      }
      try? await Task.sleep(for: pollingInterval)
    }

    return process.isRunning
  }

  private func waitForProcessExit(
    _ process: any SimulatorRecordingProcess,
    timeout: Duration
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while process.isRunning {
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: pollingInterval)
    }
    return true
  }

  private func waitForFinalizedMovie(at url: URL) async -> SimulatorRecordingFileValidation {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: finalizationTimeout)
    var previousFinalizedSize: Int64?

    while true {
      let latest = SimulatorRecordingFileValidator.validate(url: url)
      if latest.isFinalized {
        if previousFinalizedSize == latest.fileSizeBytes || clock.now >= deadline {
          return latest
        }
        previousFinalizedSize = latest.fileSizeBytes
      } else if clock.now >= deadline {
        return latest
      }

      try? await Task.sleep(for: pollingInterval)
    }
  }

  private func validationError(
    from validation: SimulatorRecordingFileValidation,
    stopResult: ProcessStopResult
  ) -> String? {
    // A finalized, stable MP4 is usable even when the recorder needed a
    // forced stop — the file already validated, so don't discard it over
    // the process's exit style. Only a recorder that never exited (and may
    // still be writing) keeps the recording unusable.
    if validation.isFinalized, stopResult.exited {
      return nil
    }

    var messages: [String] = []
    if stopResult.wasForced {
      messages.append("Recording process did not stop gracefully.")
    }
    if !stopResult.exited {
      messages.append("Recording process did not exit after fallback termination.")
    }

    if let validationError = validation.errorDescription {
      messages.append(validationError)
    }
    let diagnostic = Self.shortDiagnostic(stopResult.diagnosticOutput)
    if !diagnostic.isEmpty, !diagnostic.contains("Recording started") {
      messages.append("simctl: \(diagnostic)")
    }
    return messages.joined(separator: " ")
  }

  private static func shortDiagnostic(_ output: String) -> String {
    output
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .prefix(500)
      .description
  }

  public static func defaultRecordingsDirectory(fileManager: FileManager = .default) -> URL {
    let appSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    return appSupportURL
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("Simulator Recordings", isDirectory: true)
  }

  public static func deleteRecordingFile(at path: String, fileManager: FileManager = .default) throws {
    let framesPath = SimulatorRecordingFrameSampler.frameDirectoryPath(forRecordingPath: path)
    if fileManager.fileExists(atPath: framesPath) {
      try? fileManager.removeItem(atPath: framesPath)
    }

    let url = URL(fileURLWithPath: path)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  static func recordingFileName(
    udid: String,
    startedAt: Date,
    requestedFileName: String?
  ) throws -> String {
    if let requestedFileName,
       !requestedFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let trimmed = requestedFileName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed == (trimmed as NSString).lastPathComponent,
            !trimmed.contains("\0") else {
        throw SimulatorRecordingError.invalidFileName(requestedFileName)
      }
      return trimmed.lowercased().hasSuffix(".mp4") ? trimmed : "\(trimmed).mp4"
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: startedAt)
      .replacingOccurrences(of: ":", with: "-")
    let safeUDID = udid.map { character -> Character in
      character.isLetter || character.isNumber || character == "-" ? character : "_"
    }
    return "agenthub-simulator-\(String(safeUDID))-\(timestamp).mp4"
  }
}
