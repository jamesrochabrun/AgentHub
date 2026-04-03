//
//  SimulatorScreenshotService.swift
//  SwiftUIPreviewKit
//
//  Captures screenshots from the iOS Simulator via `xcrun simctl io`.
//

import CryptoKit
import Foundation

public actor SimulatorScreenshotService: SimulatorScreenshotServiceProtocol {

  public init() {}

  // MARK: - State

  private var pollingTasks: [UUID: Task<Void, Never>] = [:]

  // MARK: - SimulatorScreenshotServiceProtocol

  public func captureScreenshot(udid: String, outputPath: String) async throws {
    let xcrun = try Self.findXcrun()
    try await Self.runProcess(
      executablePath: xcrun,
      arguments: ["simctl", "io", udid, "screenshot", "--type=png", outputPath]
    )
  }

  public func startPolling(
    udid: String,
    interval: TimeInterval,
    onChange: @escaping @Sendable (String) -> Void
  ) async -> UUID {
    let id = UUID()
    let captureDir = Self.captureDirectory()

    let task = Task.detached { [weak self] in
      var previousHash: String?

      while !Task.isCancelled {
        let outputPath = (captureDir as NSString)
          .appendingPathComponent("capture-\(id.uuidString).png")

        do {
          try await self?.captureScreenshot(udid: udid, outputPath: outputPath)
          let hash = Self.fileHash(at: outputPath)
          if hash != previousHash {
            previousHash = hash
            onChange(outputPath)
          }
        } catch {
          // Capture failed — skip this frame
        }

        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
    }

    pollingTasks[id] = task
    return id
  }

  public func stopPolling(id: UUID) async {
    pollingTasks[id]?.cancel()
    pollingTasks[id] = nil

    // Clean up capture file
    let captureDir = Self.captureDirectory()
    let capturePath = (captureDir as NSString)
      .appendingPathComponent("capture-\(id.uuidString).png")
    try? FileManager.default.removeItem(atPath: capturePath)
  }

  // MARK: - xcrun location

  private static func findXcrun() throws -> String {
    let candidates = [
      "/usr/bin/xcrun",
      "/usr/local/bin/xcrun",
      "/opt/homebrew/bin/xcrun",
    ]
    for path in candidates {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }
    throw SimulatorScreenshotError.xcrunNotFound
  }

  // MARK: - Process execution

  private static func runProcess(executablePath: String, arguments: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = arguments
      process.standardOutput = FileHandle.nullDevice
      let errorPipe = Pipe()
      process.standardError = errorPipe

      process.terminationHandler = { proc in
        if proc.terminationStatus == 0 {
          continuation.resume()
        } else {
          let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
          let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
          continuation.resume(throwing: SimulatorScreenshotError.captureFailed(errorMessage))
        }
      }

      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  // MARK: - File hashing

  private static func fileHash(at path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Capture directory

  static func captureDirectory() -> String {
    let dir = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("AgentHub-PreviewCaptures")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }
}

// MARK: - Errors

public enum SimulatorScreenshotError: LocalizedError, Sendable {
  case xcrunNotFound
  case captureFailed(String)

  public var errorDescription: String? {
    switch self {
    case .xcrunNotFound:
      return "xcrun not found. Ensure Xcode command line tools are installed."
    case .captureFailed(let message):
      return "Screenshot capture failed: \(message)"
    }
  }
}
