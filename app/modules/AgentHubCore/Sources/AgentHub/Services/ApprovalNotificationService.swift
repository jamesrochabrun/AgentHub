//
//  ApprovalNotificationService.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif
import UserNotifications

// MARK: - ApprovalNotificationService

/// Service for playing alert sounds and sending push notifications when tools need approval
public final class ApprovalNotificationService {

  // MARK: - Singleton

  public static let shared = ApprovalNotificationService()

  // MARK: - Initialization

  private init() {}

  // MARK: - Permission

  @discardableResult
  public func requestPermission() async -> Bool {
    do {
      let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      return granted
    } catch {
      return false
    }
  }

  // MARK: - Send Approval Notification

  /// Send an approval notification (sound and/or push) when a tool needs approval
  /// - Parameters:
  ///   - sessionId: The session ID
  ///   - toolName: The name of the tool awaiting approval
  ///   - projectPath: The project path
  ///   - model: The Claude model being used (optional)
  ///   - lastMessage: The last user message for context (optional)
  public func sendApprovalNotification(
    sessionId: String,
    toolName: String,
    projectPath: String?,
    model: String?,
    lastMessage: String? = nil
  ) {
    playAlertSound()
    if pushNotificationsEnabled {
      Task(priority: .userInitiated) {
        await sendPushNotification(toolName: toolName, projectPath: projectPath, sessionId: sessionId)
      }
    }
  }

  // MARK: - Private

  private var soundsEnabled: Bool {
    UserDefaults.standard.object(forKey: AgentHubDefaults.notificationSoundsEnabled) as? Bool ?? true
  }

  private var pushNotificationsEnabled: Bool {
    UserDefaults.standard.object(forKey: AgentHubDefaults.pushNotificationsEnabled) as? Bool ?? true
  }

  private func playAlertSound() {
    guard soundsEnabled else { return }

    #if canImport(AppKit)
    // Play system alert sound
    NSSound.beep()
    #endif
  }

  private func sendPushNotification(toolName: String, projectPath: String?, sessionId: String) async {
    let content = UNMutableNotificationContent()
    content.title = "Approval Required"
    content.body = "\(toolName) needs your approval"
    if let projectPath {
      content.subtitle = URL(fileURLWithPath: projectPath).lastPathComponent
    }
    content.sound = .none
    content.userInfo = ["sessionId": sessionId]

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let request = UNNotificationRequest(
      identifier: "approval-\(sessionId)",
      content: content,
      trigger: trigger
    )

    do {
      try await UNUserNotificationCenter.current().add(request)
    } catch {
      // Silently fail — notification is a best-effort enhancement
    }
  }
}
