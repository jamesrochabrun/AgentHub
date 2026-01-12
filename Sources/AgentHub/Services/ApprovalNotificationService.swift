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

// MARK: - ApprovalNotificationService

/// Service for playing alert sounds when tools need approval
public final class ApprovalNotificationService {

  // MARK: - Singleton

  public static let shared = ApprovalNotificationService()

  // MARK: - Initialization

  private init() {}

  // MARK: - Permission (no longer needed, but keep for API compatibility)

  @discardableResult
  public func requestPermission() async -> Bool {
    // No permission needed for playing sounds
    return true
  }

  // MARK: - Play Alert Sound

  /// Play an alert sound when a tool needs approval
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
    print("[ApprovalNotification] Tool '\(toolName)' needs approval - playing sound")
    playAlertSound()
  }

  // MARK: - Private

  private func playAlertSound() {
    #if canImport(AppKit)
    // Play system alert sound
    NSSound.beep()
    #endif
  }
}
