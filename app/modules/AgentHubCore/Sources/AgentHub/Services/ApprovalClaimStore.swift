import Foundation

// MARK: - ApprovalClaimStoreProtocol

/// Manages the claim-file directory that gates the AgentHub approval hook.
///
/// The hook script refuses to write to the sidecar for any session without a
/// matching claim file, so these two calls bracket the window during which
/// AgentHub wants to observe approvals for a session:
///
/// ```
/// await claimStore.claim(sessionId: session.id)    // startPolling
/// // … monitor session …
/// await claimStore.release(sessionId: session.id)  // stopPolling
/// ```
///
/// Claims are stored as empty marker files at
/// `~/Library/Application Support/AgentHub/claims/{sessionId}`. The directory
/// is wiped on `resetAll()` so a hard crash never leaves stale claims that
/// would unmask external sessions to our hook.
public protocol ApprovalClaimStoreProtocol: AnyObject, Sendable {
  func claim(sessionId: String) async
  func release(sessionId: String) async
  func resetAll() async
}

// MARK: - ApprovalClaimStore

public actor ApprovalClaimStore: ApprovalClaimStoreProtocol {

  private let claimsDirectory: URL
  private let fileManager: FileManager

  public init(
    claimsDirectory: URL = ClaudeHookPaths.claimsDirectoryURL,
    fileManager: FileManager = .default
  ) {
    self.claimsDirectory = claimsDirectory
    self.fileManager = fileManager
  }

  public func claim(sessionId: String) async {
    guard !sessionId.isEmpty else { return }
    ensureDirectory()
    let url = claimsDirectory.appendingPathComponent(sessionId, isDirectory: false)
    if !fileManager.fileExists(atPath: url.path) {
      fileManager.createFile(atPath: url.path, contents: nil)
    }
  }

  public func release(sessionId: String) async {
    guard !sessionId.isEmpty else { return }
    let url = claimsDirectory.appendingPathComponent(sessionId, isDirectory: false)
    try? fileManager.removeItem(at: url)
  }

  public func resetAll() async {
    if fileManager.fileExists(atPath: claimsDirectory.path) {
      try? fileManager.removeItem(at: claimsDirectory)
    }
    ensureDirectory()
  }

  private func ensureDirectory() {
    try? fileManager.createDirectory(at: claimsDirectory, withIntermediateDirectories: true)
  }
}
