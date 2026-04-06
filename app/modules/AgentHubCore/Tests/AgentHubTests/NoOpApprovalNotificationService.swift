import Foundation
@testable import AgentHubCore

/// No-op implementation used in tests to avoid hitting `UNUserNotificationCenter`.
final class NoOpApprovalNotificationService: ApprovalNotificationServiceProtocol, @unchecked Sendable {
  func requestPermission() async -> Bool { false }
  func sendApprovalNotification(
    sessionId: String,
    toolName: String,
    projectPath: String?,
    model: String?,
    lastMessage: String?
  ) {}
}
