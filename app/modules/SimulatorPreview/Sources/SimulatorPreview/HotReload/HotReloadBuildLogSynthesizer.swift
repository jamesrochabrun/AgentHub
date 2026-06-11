import Foundation

/// Writes a synthetic `.xcactivitylog` so the injection engine can find
/// per-file compile commands.
///
/// InjectionLite replays the `swift-frontend` invocation recorded in the
/// newest activity log under `<derived data>/Logs/Build`
/// (`gunzip | grep " -primary-file <file> "`). Xcode 26's command-line
/// builds persist only zero-byte activity logs, so armed builds run without
/// `-quiet` plus `EMIT_FRONTEND_COMMAND_LINES=YES` — putting the frontend
/// command lines on xcodebuild's stdout, which AgentHub already captures —
/// and this type gzips those lines into a log the engine can consume.
public enum HotReloadBuildLogSynthesizer {

  /// Filters the captured xcodebuild output to the frontend command lines
  /// and writes them gzip-compressed as a uniquely named `.xcactivitylog`
  /// in `Logs/Build`. Returns nil when the output contains no commands
  /// (nothing recompiled — earlier logs already cover every file).
  @discardableResult
  public static func writeSyntheticLog(
    buildOutput: Data,
    derivedDataPath: String,
    fileManager: FileManager = .default
  ) throws -> URL? {
    let output = String(decoding: buildOutput, as: UTF8.self)
    let commandLines = output
      .components(separatedBy: .newlines)
      .filter { $0.contains(" -primary-file ") }
    guard !commandLines.isEmpty else { return nil }

    let logsDirectory = URL(fileURLWithPath: derivedDataPath)
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Build", isDirectory: true)
    try fileManager.createDirectory(
      at: logsDirectory, withIntermediateDirectories: true)

    let content = Data(commandLines.joined(separator: "\n").utf8)
    let logURL = logsDirectory
      .appendingPathComponent("agenthub-\(UUID().uuidString).xcactivitylog")
    try gzip(content, to: logURL)
    return logURL
  }

  /// The engine reads logs with `gunzip`, so the file must be a real gzip
  /// container — produced with the system tool rather than hand-rolling the
  /// header around raw deflate.
  private static func gzip(_ data: Data, to destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()

    input.fileHandleForWriting.write(data)
    try input.fileHandleForWriting.close()
    let compressed = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0, !compressed.isEmpty else {
      throw NSError(
        domain: "HotReloadBuildLogSynthesizer",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "gzip failed"])
    }
    try compressed.write(to: destination)
  }
}
