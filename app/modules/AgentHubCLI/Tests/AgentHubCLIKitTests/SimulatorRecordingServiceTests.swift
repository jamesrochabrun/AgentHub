import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SimulatorRecordingService")
struct SimulatorRecordingServiceTests {
  @Test("Start invokes simctl recordVideo and stop returns file metadata")
  func startAndStopRecording() async throws {
    let directory = try temporarySimulatorRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let process = MockRecordingProcess()
    let runner = MockRecordingRunner(process: process)
    let dates = DateSequence([
      Date(timeIntervalSince1970: 1_000),
      Date(timeIntervalSince1970: 1_010)
    ])
    let service = SimulatorRecordingService(
      runner: runner,
      dateProvider: { dates.next() },
      finalizationTimeout: .zero,
      pollingInterval: .zero
    )

    let started = try await service.startRecording(
      udid: "UDID-1",
      outputDirectory: directory,
      fileName: "motion-check"
    )
    let mp4Data = minimalMP4Data()
    try mp4Data.write(to: URL(fileURLWithPath: started.outputPath))
    let result = try await service.stopRecording(udid: "UDID-1")

    #expect(runner.recordedArguments() == [
      ["simctl", "io", "UDID-1", "recordVideo", "--force", directory.appendingPathComponent("motion-check.mp4").path]
    ])
    #expect(process.interruptCallCount == 1)
    #expect(process.terminateCallCount == 0)
    #expect(process.waitCallCount == 1)
    #expect(result.outputPath == started.outputPath)
    #expect(result.duration == 10)
    #expect(result.fileExists == true)
    #expect(result.fileSizeBytes == Int64(mp4Data.count))
    #expect(result.isFinalized == true)
    #expect(result.validationError == nil)
    #expect(result.isUsable == true)
  }

  @Test("Stop falls back to terminate when interrupt does not exit")
  func stopFallsBackToTerminate() async throws {
    let directory = try temporarySimulatorRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let process = MockRecordingProcess(exitsOnInterrupt: false)
    let service = SimulatorRecordingService(
      runner: MockRecordingRunner(process: process),
      dateProvider: { Date(timeIntervalSince1970: 1_000) },
      gracefulStopTimeout: .zero,
      forcedStopTimeout: .zero,
      finalizationTimeout: .zero,
      pollingInterval: .zero
    )

    let started = try await service.startRecording(
      udid: "UDID-1",
      outputDirectory: directory,
      fileName: "forced-stop"
    )
    try minimalMP4Data(includeMoov: false).write(to: URL(fileURLWithPath: started.outputPath))
    let result = try await service.stopRecording(udid: "UDID-1")

    #expect(process.interruptCallCount == 1)
    #expect(process.terminateCallCount == 1)
    #expect(result.isUsable == false)
    #expect(result.validationError?.contains("did not stop gracefully") == true)
  }

  @Test("Stop reports incomplete MP4 when moov atom is missing")
  func stopReportsMissingMoovAtom() async throws {
    let directory = try temporarySimulatorRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let service = SimulatorRecordingService(
      runner: MockRecordingRunner(process: MockRecordingProcess()),
      dateProvider: { Date(timeIntervalSince1970: 1_000) },
      finalizationTimeout: .zero,
      pollingInterval: .zero
    )

    let started = try await service.startRecording(
      udid: "UDID-1",
      outputDirectory: directory,
      fileName: "incomplete"
    )
    try minimalMP4Data(includeMoov: false).write(to: URL(fileURLWithPath: started.outputPath))
    let result = try await service.stopRecording(udid: "UDID-1")

    #expect(result.fileExists == true)
    #expect(result.isFinalized == false)
    #expect(result.isUsable == false)
    #expect(result.validationError?.contains("moov") == true)
  }

  @Test("Discard stops active recording and removes file")
  func discardStopsActiveRecordingAndRemovesFile() async throws {
    let directory = try temporarySimulatorRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let process = MockRecordingProcess()
    let dates = DateSequence([
      Date(timeIntervalSince1970: 1_000),
      Date(timeIntervalSince1970: 1_006)
    ])
    let service = SimulatorRecordingService(
      runner: MockRecordingRunner(process: process),
      dateProvider: { dates.next() },
      finalizationTimeout: .zero,
      pollingInterval: .zero
    )

    let started = try await service.startRecording(
      udid: "UDID-1",
      outputDirectory: directory,
      fileName: "discard-me"
    )
    try minimalMP4Data().write(to: URL(fileURLWithPath: started.outputPath))

    let result = try await service.discardRecording(udid: "UDID-1")

    #expect(process.interruptCallCount == 1)
    #expect(result.outputPath == started.outputPath)
    #expect(FileManager.default.fileExists(atPath: started.outputPath) == false)
  }

  @Test("Start rejects duplicate active recording for same simulator")
  func duplicateStartRejected() async throws {
    let directory = try temporarySimulatorRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let service = SimulatorRecordingService(
      runner: MockRecordingRunner(process: MockRecordingProcess()),
      dateProvider: { Date(timeIntervalSince1970: 1_000) }
    )

    _ = try await service.startRecording(
      udid: "UDID-1",
      outputDirectory: directory,
      fileName: "first"
    )

    await #expect(throws: SimulatorRecordingError.alreadyRecording("UDID-1")) {
      _ = try await service.startRecording(
        udid: "UDID-1",
        outputDirectory: directory,
        fileName: "second"
      )
    }
  }

  @Test("Start surfaces simctl stderr when recording cannot begin")
  func startSurfacesSimctlDiagnostic() async throws {
    let directory = try temporarySimulatorRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let process = MockRecordingProcess(
      isRunning: false,
      diagnosticOutput: "Host recording is already in progress"
    )
    let service = SimulatorRecordingService(
      runner: MockRecordingRunner(process: process),
      dateProvider: { Date(timeIntervalSince1970: 1_000) },
      startConfirmationTimeout: .zero,
      pollingInterval: .zero
    )

    await #expect(throws: SimulatorRecordingError.startFailed("Host recording is already in progress")) {
      _ = try await service.startRecording(
        udid: "UDID-1",
        outputDirectory: directory,
        fileName: "busy"
      )
    }
  }

  @Test("Start failure removes partial output file")
  func startFailureRemovesPartialOutputFile() async throws {
    let directory = try temporarySimulatorRecordingDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let process = MockRecordingProcess(
      isRunning: false,
      diagnosticOutput: "Host recording is already in progress"
    )
    let runner = MockRecordingRunner(process: process) { arguments in
      guard let outputPath = arguments.last else { return }
      try Data([0x00]).write(to: URL(fileURLWithPath: outputPath))
    }
    let service = SimulatorRecordingService(
      runner: runner,
      dateProvider: { Date(timeIntervalSince1970: 1_000) },
      startConfirmationTimeout: .zero,
      pollingInterval: .zero
    )
    let outputURL = directory.appendingPathComponent("busy.mp4")

    await #expect(throws: SimulatorRecordingError.startFailed("Host recording is already in progress")) {
      _ = try await service.startRecording(
        udid: "UDID-1",
        outputDirectory: directory,
        fileName: "busy"
      )
    }

    #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
  }

  @Test("Generated recording filenames are path safe")
  func generatedFileNameIsPathSafe() throws {
    let fileName = try SimulatorRecordingService.recordingFileName(
      udid: "A/B:C",
      startedAt: Date(timeIntervalSince1970: 1_000),
      requestedFileName: nil
    )

    #expect(fileName.hasPrefix("agenthub-simulator-A_B_C-"))
    #expect(fileName.hasSuffix(".mp4"))
    #expect(!fileName.contains("/"))
    #expect(!fileName.contains(":"))
  }

  @Test("Requested recording filenames cannot escape output directory")
  func requestedFileNameCannotEscapeDirectory() throws {
    #expect(throws: SimulatorRecordingError.invalidFileName("../escape")) {
      _ = try SimulatorRecordingService.recordingFileName(
        udid: "UDID",
        startedAt: Date(),
        requestedFileName: "../escape"
      )
    }
  }
}

private final class MockRecordingProcess: SimulatorRecordingProcess, @unchecked Sendable {
  var isRunning: Bool
  var terminationStatus: Int32 = 0
  var diagnosticOutput: String
  var interruptCallCount = 0
  var terminateCallCount = 0
  var waitCallCount = 0

  private let exitsOnInterrupt: Bool
  private let exitsOnTerminate: Bool

  init(
    isRunning: Bool = true,
    diagnosticOutput: String = "Recording started",
    exitsOnInterrupt: Bool = true,
    exitsOnTerminate: Bool = true
  ) {
    self.isRunning = isRunning
    self.diagnosticOutput = diagnosticOutput
    self.exitsOnInterrupt = exitsOnInterrupt
    self.exitsOnTerminate = exitsOnTerminate
  }

  func interrupt() {
    interruptCallCount += 1
    if exitsOnInterrupt {
      isRunning = false
    }
  }

  func terminate() {
    terminateCallCount += 1
    if exitsOnTerminate {
      isRunning = false
    }
  }

  func waitUntilExit() {
    waitCallCount += 1
  }
}

private final class MockRecordingRunner: SimulatorRecordingProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let process: MockRecordingProcess
  private let onStart: ([String]) throws -> Void
  private var arguments: [[String]] = []

  init(process: MockRecordingProcess, onStart: @escaping ([String]) throws -> Void = { _ in }) {
    self.process = process
    self.onStart = onStart
  }

  func start(arguments: [String]) throws -> any SimulatorRecordingProcess {
    lock.lock()
    self.arguments.append(arguments)
    lock.unlock()
    try onStart(arguments)
    return process
  }

  func recordedArguments() -> [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return arguments
  }
}

private final class DateSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var dates: [Date]

  init(_ dates: [Date]) {
    self.dates = dates
  }

  func next() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return dates.isEmpty ? Date() : dates.removeFirst()
  }
}

private func temporarySimulatorRecordingDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-simulator-recording-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("recordings", isDirectory: true)
}

private func minimalMP4Data(includeMoov: Bool = true) -> Data {
  var data = Data()
  data.append(mp4Box(type: "ftyp", payload: Data("isom0000".utf8)))
  data.append(mp4Box(type: "mdat", payload: Data([0x00])))
  if includeMoov {
    data.append(mp4Box(type: "moov"))
  }
  return data
}

private func mp4Box(type: String, payload: Data = Data()) -> Data {
  var size = UInt32(payload.count + 8).bigEndian
  var data = Data()
  withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
  data.append(Data(type.utf8.prefix(4)))
  data.append(payload)
  return data
}
