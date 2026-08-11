//
//  VoiceHUDContract.swift
//  AgentHubVoice
//
//  The app-facing contract for hosting the voice HUD. A host app implements
//  `VoiceHUDHost` to supply targets, tools, and dictation delivery; the HUD
//  panel module stays app-agnostic and reusable.
//

import Foundation
import SwiftUI

// MARK: - Presenting

@MainActor
public protocol VoiceHUDPresenting: AnyObject {
  var isVisible: Bool { get }
  func show()
  func hide()
}

public extension VoiceHUDPresenting {
  func toggle() {
    isVisible ? hide() : show()
  }
}

@MainActor
public final class NoOpVoiceHUDPresenter: VoiceHUDPresenting {
  public var isVisible: Bool { false }

  public init() {}

  public func show() {}
  public func hide() {}
}

// MARK: - Host

/// A destination the user can direct voice prompts or dictation at.
public struct VoiceHUDTarget: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  /// Short qualifier shown next to the name (e.g. a provider or project).
  public let detail: String?

  public init(id: String, name: String, detail: String? = nil) {
    self.id = id
    self.name = name
    self.detail = detail
  }
}

public enum VoiceDictationOutcome: Equatable, Sendable {
  case delivered
  case failed(String)
}

/// Implemented by the host app to back the voice HUD.
@MainActor
public protocol VoiceHUDHost: AnyObject {
  /// Candidate targets, most relevant first.
  var targets: [VoiceHUDTarget] { get }

  /// Resolves the effective target; `manualId` is the user's explicit pick.
  func resolveTarget(manualId: String?) -> VoiceHUDTarget?

  /// Tools exposed to the realtime conversation.
  func makeToolRegistry() -> VoiceToolRegistry

  /// The OpenAI API key, or nil when not configured yet.
  func resolveAPIKey() async throws -> String?

  /// Delivers a completed dictation transcript to the target.
  func deliverDictation(
    _ transcript: String,
    to targetId: String
  ) -> VoiceDictationOutcome
}

// MARK: - Configuration

/// UserDefaults keys the HUD reads and writes. The host app supplies its own
/// namespaced keys so the panel never hardcodes another app's preferences.
public struct VoiceHUDSettingsKeys: Sendable {
  public let mode: String
  public let realtimeModel: String
  public let voiceName: String
  public let vadEagerness: String
  public let dictationModel: String
  public let language: String
  public let allowBargeIn: String
  public let hudFrame: String
  public let screenCaptureEnabled: String
  public let onboardingCompleted: String

  public init(
    mode: String,
    realtimeModel: String,
    voiceName: String,
    vadEagerness: String,
    dictationModel: String,
    language: String,
    allowBargeIn: String,
    hudFrame: String,
    screenCaptureEnabled: String,
    onboardingCompleted: String
  ) {
    self.mode = mode
    self.realtimeModel = realtimeModel
    self.voiceName = voiceName
    self.vadEagerness = vadEagerness
    self.dictationModel = dictationModel
    self.language = language
    self.allowBargeIn = allowBargeIn
    self.hudFrame = hudFrame
    self.screenCaptureEnabled = screenCaptureEnabled
    self.onboardingCompleted = onboardingCompleted
  }
}

public struct VoiceHUDConfiguration: Sendable {
  /// Product name used in HUD and onboarding copy (e.g. "AgentHub").
  public let productName: String
  public let settings: VoiceHUDSettingsKeys
  /// Host brand color for selected/emphasized HUD controls. When nil the HUD
  /// falls back to the system accent color.
  public let accentColor: Color?

  public init(
    productName: String,
    settings: VoiceHUDSettingsKeys,
    accentColor: Color? = nil
  ) {
    self.productName = productName
    self.settings = settings
    self.accentColor = accentColor
  }
}
