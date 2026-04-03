//
//  PreviewBuildService.swift
//  SwiftUIPreviewKit
//
//  Orchestrates the full preview build pipeline: scan → generate → build → capture.
//  Dependencies are injected via init (protocols), not singletons.
//

import Foundation

// MARK: - Process helpers (internal)

final class PreviewProcessRef: @unchecked Sendable {
  let process: Process
  let errorPipe: Pipe

  init(process: Process, errorPipe: Pipe) {
    self.process = process
    self.errorPipe = errorPipe
  }
}

// MARK: - PreviewBuildService

@MainActor
@Observable
public final class PreviewBuildService: PreviewBuildServiceProtocol {

  // MARK: - Dependencies

  private let scanner: PreviewScannerProtocol
  private let hostGenerator: PreviewHostGeneratorProtocol
  private let screenshotService: SimulatorScreenshotServiceProtocol

  // MARK: - Observable state

  public private(set) var buildState: PreviewBuildState = .idle
  public private(set) var previews: [PreviewDeclaration] = []
  public private(set) var selectedPreview: PreviewDeclaration?
  public private(set) var capturedImagePath: String?

  /// Consumer provides this to trigger user project builds.
  /// Parameters: (projectPath, udid) → derivedDataPath
  public var onBuildUserProject: ((String, String) async throws -> String)?

  // MARK: - Task management

  private var buildTask: Task<Void, Never>?
  private var processRef: PreviewProcessRef?
  private var pollingId: UUID?

  // MARK: - Init

  public init(
    scanner: PreviewScannerProtocol,
    hostGenerator: PreviewHostGeneratorProtocol,
    screenshotService: SimulatorScreenshotServiceProtocol
  ) {
    self.scanner = scanner
    self.hostGenerator = hostGenerator
    self.screenshotService = screenshotService
  }

  // MARK: - PreviewBuildServiceProtocol

  public func scanPreviews(projectPath: String, moduleName: String?) async {
    buildState = .scanningPreviews
    let found = await scanner.scanForPreviews(in: projectPath, moduleName: moduleName)
    previews = found
    buildState = .idle
  }

  public func buildPreview(
    _ preview: PreviewDeclaration,
    udid: String,
    projectPath: String
  ) async {
    cancelBuild()
    selectedPreview = preview

    buildTask = Task { [weak self] in
      guard let self else { return }

      do {
        // Phase 1: Build user project if needed
        await MainActor.run { self.buildState = .buildingUserProject }
        let derivedDataPath: String
        if let callback = self.onBuildUserProject {
          derivedDataPath = try await callback(projectPath, udid)
        } else {
          throw PreviewBuildError.noBuildCallback
        }

        if Task.isCancelled { return }

        // Phase 2: Generate host project
        await MainActor.run { self.buildState = .generatingHost }
        let scheme = preview.moduleName ?? "App"
        let host = try await self.hostGenerator.generateHostProject(
          for: preview,
          userDerivedDataPath: derivedDataPath,
          scheme: scheme
        )

        if Task.isCancelled { return }

        // Phase 3: Build host project
        await MainActor.run { self.buildState = .buildingHost }
        try await self.buildHostProject(host)

        if Task.isCancelled { return }

        // Phase 4: Install on simulator
        await MainActor.run { self.buildState = .installing }
        let appPath = "\(host.derivedDataPath)/Build/Products/Debug-iphonesimulator/PreviewHost.app"
        try await self.installAndLaunch(appPath: appPath, bundleId: host.bundleIdentifier, udid: udid)

        if Task.isCancelled { return }

        // Phase 5: Capture screenshot
        await MainActor.run { self.buildState = .capturing }
        try await Task.sleep(nanoseconds: 500_000_000)  // Brief delay for app to render

        let outputPath = (SimulatorScreenshotService.captureDirectory() as NSString)
          .appendingPathComponent("preview-\(preview.id.uuidString).png")
        try await self.screenshotService.captureScreenshot(udid: udid, outputPath: outputPath)

        await MainActor.run {
          self.capturedImagePath = outputPath
          self.buildState = .ready(imagePath: outputPath)
        }
      } catch {
        if !Task.isCancelled {
          await MainActor.run {
            self.buildState = .failed(error: error.localizedDescription)
          }
        }
      }
    }
  }

  public func cancelBuild() {
    buildTask?.cancel()
    buildTask = nil
    processRef?.process.terminate()
    processRef = nil
    if let id = pollingId {
      let service = screenshotService
      Task { await service.stopPolling(id: id) }
      pollingId = nil
    }
    buildState = .idle
    capturedImagePath = nil
  }

  // MARK: - Host build

  private func buildHostProject(_ host: GeneratedPreviewHost) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = [
        "xcodebuild",
        "build",
        "-project", host.projectPath,
        "-scheme", host.scheme,
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", host.derivedDataPath,
        "-quiet",
      ]
      process.standardOutput = FileHandle.nullDevice
      let errorPipe = Pipe()
      process.standardError = errorPipe

      let ref = PreviewProcessRef(process: process, errorPipe: errorPipe)
      self.processRef = ref

      process.terminationHandler = { proc in
        if proc.terminationStatus == 0 {
          continuation.resume()
        } else {
          let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
          let output = String(data: errorData, encoding: .utf8) ?? ""
          let errorLines = Self.extractBuildErrors(from: output)
          continuation.resume(throwing: PreviewBuildError.hostBuildFailed(errorLines))
        }
      }

      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  // MARK: - Install & Launch

  private func installAndLaunch(appPath: String, bundleId: String, udid: String) async throws {
    // Install
    try await Self.runSimctl(arguments: ["install", udid, appPath])
    // Launch
    try await Self.runSimctl(arguments: ["launch", udid, bundleId])
  }

  private static func runSimctl(arguments: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = ["simctl"] + arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice

      process.terminationHandler = { proc in
        if proc.terminationStatus == 0 {
          continuation.resume()
        } else {
          continuation.resume(throwing: PreviewBuildError.simctlFailed(
            "simctl \(arguments.first ?? "") exited with code \(proc.terminationStatus)"
          ))
        }
      }

      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  // MARK: - Error extraction

  static func extractBuildErrors(from output: String) -> String {
    let errorLines = output.components(separatedBy: "\n")
      .filter { $0.contains(": error:") }
    if errorLines.isEmpty {
      return output.suffix(500).description
    }
    return errorLines.joined(separator: "\n")
  }
}

// MARK: - Errors

public enum PreviewBuildError: LocalizedError, Sendable {
  case noBuildCallback
  case hostBuildFailed(String)
  case simctlFailed(String)

  public var errorDescription: String? {
    switch self {
    case .noBuildCallback:
      return "No build callback configured. Set onBuildUserProject to build the user's project."
    case .hostBuildFailed(let errors):
      return "Preview host build failed:\n\(errors)"
    case .simctlFailed(let message):
      return "Simulator command failed: \(message)"
    }
  }
}
