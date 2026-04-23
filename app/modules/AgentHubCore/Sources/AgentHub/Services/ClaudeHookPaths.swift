import Foundation

/// Canonical filesystem locations shared by the approval hook script,
/// `ApprovalClaimStore`, `ClaudeHookSidecarWatcher`, and `ClaudeHookInstaller`.
///
/// The script reads `claims/{sessionId}` and writes `approvals/{sessionId}.jsonl`
/// under the same base directory this type resolves. Keeping the paths in one
/// place ensures the Swift side and the shipped shell script agree.
public enum ClaudeHookPaths {

  public static var appSupportBaseURL: URL {
    let fm = FileManager.default
    let base = (try? fm.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)
    return base.appendingPathComponent("AgentHub", isDirectory: true)
  }

  public static var claimsDirectoryURL: URL {
    appSupportBaseURL.appendingPathComponent("claims", isDirectory: true)
  }

  public static var approvalsDirectoryURL: URL {
    appSupportBaseURL.appendingPathComponent("approvals", isDirectory: true)
  }

  public static func claimURL(for sessionId: String) -> URL {
    claimsDirectoryURL.appendingPathComponent(sessionId, isDirectory: false)
  }

  public static func approvalsURL(for sessionId: String) -> URL {
    approvalsDirectoryURL.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
  }

  /// Shared install location of the hook script. One copy for the whole app;
  /// every monitored project references it by absolute path from its
  /// `settings.local.json`. Keeping the script out of the project's `.claude/`
  /// directory prevents it from ever being committed to git (even if the user
  /// has a loose `.gitignore`).
  public static var sharedScriptURL: URL {
    appSupportBaseURL
      .appendingPathComponent("hooks", isDirectory: true)
      .appendingPathComponent("agenthub-approval.sh", isDirectory: false)
  }

  /// `settings.local.json` location inside a monitored project. This is the
  /// ONLY file we touch inside a user's repo, and Claude Code treats it as
  /// personal/gitignored by convention.
  public static func settingsLocalURL(inProjectAt projectPath: String) -> URL {
    URL(fileURLWithPath: projectPath, isDirectory: true)
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("settings.local.json", isDirectory: false)
  }

  /// Bundle resource URL for the shipped hook script, if present.
  public static func bundledScriptURL() -> URL? {
    Bundle.module.url(forResource: "agenthub-approval", withExtension: "sh", subdirectory: "ClaudeHook")
  }
}
