import Foundation

/// Captures a PNG of a booted simulator via public `simctl` for the
/// `agenthub_simulator_screenshot` MCP tool. Writes to a temp-scoped file
/// whose path is returned so the calling agent can read the image.
public struct SimulatorScreenshotService: Sendable {
  public init() {}

  public static func defaultOutputDirectory(fileManager: FileManager = .default) -> URL {
    fileManager.temporaryDirectory
      .appendingPathComponent("agenthub-simulator-screenshots", isDirectory: true)
  }

  /// "sim-<udid prefix>-<timestamp>.png" — unique enough for repeated
  /// verification loops while staying recognizable in the temp directory.
  public static func defaultFileName(udid: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "sim-\(udid.prefix(8))-\(formatter.string(from: date)).png"
  }

  @discardableResult
  public func capture(
    udid: String,
    outputDirectory: URL? = nil,
    fileName: String? = nil
  ) throws -> URL {
    let directory = outputDirectory ?? Self.defaultOutputDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var name = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if name.isEmpty {
      name = Self.defaultFileName(udid: udid)
    } else if !name.lowercased().hasSuffix(".png") {
      name += ".png"
    }
    let outputURL = directory.appendingPathComponent(name, isDirectory: false)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    // Newer simctl can't stream to stdout — a real file path is required.
    process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", outputURL.path]
    let stderr = Pipe()
    process.standardOutput = Pipe()
    process.standardError = stderr

    try process.run()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0,
          FileManager.default.fileExists(atPath: outputURL.path)
    else {
      let detail = String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw SimulatorScreenshotError.captureFailed(
        udid: udid,
        detail: detail.isEmpty ? "simctl exited with status \(process.terminationStatus)" : detail
      )
    }
    return outputURL
  }
}

public enum SimulatorScreenshotError: LocalizedError {
  case captureFailed(udid: String, detail: String)

  public var errorDescription: String? {
    switch self {
    case .captureFailed(let udid, let detail):
      return "Failed to capture a screenshot of simulator \(udid): \(detail). Is the device booted?"
    }
  }
}
