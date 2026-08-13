import Foundation

/// Resolves the base directory for AgentHub's persistent state
/// (`session_metadata.sqlite`, `approvals/`, `claims/`, `hooks/`).
///
/// Normal app runs resolve to `~/Library/Application Support/AgentHub`.
/// Two overrides exist, in priority order:
///
/// 1. `AGENTHUB_APP_SUPPORT_DIR` environment variable — explicit redirection
///    for E2E harnesses and the CLI.
/// 2. Test processes — any process with XCTest loaded (package test runners,
///    and the app itself when launched as a unit-test host) resolves to a
///    per-process temp sandbox. A test run must never be able to read or
///    write the user's real state: on 2026-08-13 a test suite sharing the
///    production sqlite caused the app to overwrite the user's workspace
///    state (tracked projects and monitored sessions) with a near-empty list.
public enum AgentHubApplicationSupport {

  /// Stable for the lifetime of the process.
  public static let baseDirectoryURL: URL = resolveBaseDirectoryURL()

  static var isTestProcess: Bool {
    NSClassFromString("XCTestCase") != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
  }

  private static func resolveBaseDirectoryURL() -> URL {
    let url: URL
    if let override = ProcessInfo.processInfo.environment["AGENTHUB_APP_SUPPORT_DIR"],
       !override.isEmpty {
      url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
    } else if isTestProcess {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentHubTestSandbox-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    } else {
      let appSupport = (try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )) ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
      url = appSupport.appendingPathComponent("AgentHub", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
