//
//  GitHubCIFailureNotificationPayload.swift
//  AgentHub
//
//  Session/PR identity carried through CI-failure notification userInfo
//

import Foundation

/// Everything a CI-failure notification tap needs to route back into the app:
/// which session to select, which PR is failing, and which checks failed.
///
/// Encoded as a JSON string inside `UNNotificationContent.userInfo` so the
/// payload survives the plist-only userInfo round-trip.
public struct GitHubCIFailureNotificationPayload: Equatable, Sendable, Codable {

  public struct FailedCheck: Equatable, Sendable, Codable {
    public let name: String
    public let workflowName: String?
    public let detailsUrl: String?

    public init(name: String, workflowName: String? = nil, detailsUrl: String? = nil) {
      self.name = name
      self.workflowName = workflowName
      self.detailsUrl = detailsUrl
    }
  }

  public let sessionId: String
  public let providerKindRawValue: String
  public let projectPath: String
  public let branchName: String
  public let prNumber: Int
  public let prTitle: String
  public let failedChecks: [FailedCheck]

  public var providerKind: SessionProviderKind? {
    SessionProviderKind(rawValue: providerKindRawValue)
  }

  public init(
    sessionId: String,
    providerKindRawValue: String,
    projectPath: String,
    branchName: String,
    prNumber: Int,
    prTitle: String,
    failedChecks: [FailedCheck]
  ) {
    self.sessionId = sessionId
    self.providerKindRawValue = providerKindRawValue
    self.projectPath = projectPath
    self.branchName = branchName
    self.prNumber = prNumber
    self.prTitle = prTitle
    self.failedChecks = failedChecks
  }

  // MARK: - userInfo round-trip

  private static let userInfoKey = "com.agenthub.notification.ciFailurePayload"

  public var userInfo: [String: Any] {
    guard let data = try? JSONEncoder().encode(self),
          let json = String(data: data, encoding: .utf8) else {
      return ["sessionId": sessionId]
    }
    return [Self.userInfoKey: json, "sessionId": sessionId]
  }

  public init?(userInfo: [AnyHashable: Any]) {
    guard let json = userInfo[Self.userInfoKey] as? String,
          let data = json.data(using: .utf8),
          let payload = try? JSONDecoder().decode(Self.self, from: data) else {
      return nil
    }
    self = payload
  }
}
