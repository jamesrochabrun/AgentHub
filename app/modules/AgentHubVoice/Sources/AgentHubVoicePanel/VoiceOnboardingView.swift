//
//  VoiceOnboardingView.swift
//  AgentHubVoicePanel
//
//  Three-step introduction to the voice HUD: feature overview, screenshot
//  consent (with Screen Recording permission), and voice selection. Branding
//  and storage keys come from `VoiceHUDConfiguration` so any host app can
//  present it.
//

import AgentHubVoice
import SwiftUI

public struct VoiceOnboardingView: View {
  @AppStorage private var screenCaptureEnabled: Bool
  @AppStorage private var voiceName: String
  @AppStorage private var onboardingCompleted: Bool

  @State private var step = 0
  @State private var hasScreenPermission = false

  private let configuration: VoiceHUDConfiguration
  private let screenCapture: any VoiceScreenCapturing
  private let onStartVoiceChat: (() -> Void)?
  private let onDismiss: () -> Void

  public init(
    configuration: VoiceHUDConfiguration,
    screenCapture: any VoiceScreenCapturing = VoiceScreenCaptureService(),
    onStartVoiceChat: (() -> Void)? = nil,
    onDismiss: @escaping () -> Void
  ) {
    self.configuration = configuration
    self.screenCapture = screenCapture
    self.onStartVoiceChat = onStartVoiceChat
    self.onDismiss = onDismiss
    _screenCaptureEnabled = AppStorage(
      wrappedValue: true,
      configuration.settings.screenCaptureEnabled
    )
    _voiceName = AppStorage(
      wrappedValue: "marin",
      configuration.settings.voiceName
    )
    _onboardingCompleted = AppStorage(
      wrappedValue: false,
      configuration.settings.onboardingCompleted
    )
  }

  public var body: some View {
    VStack(spacing: 0) {
      dismissRow

      Group {
        switch step {
        case 0:
          VoiceOnboardingIntroStep(productName: configuration.productName)
        case 1:
          VoiceOnboardingScreenshotStep(
            isEnabled: $screenCaptureEnabled,
            productName: configuration.productName,
            hasPermission: hasScreenPermission,
            onRequestPermission: requestScreenPermission
          )
        default:
          VoiceOnboardingVoiceStep(selectedVoiceId: $voiceName)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .animation(.easeInOut(duration: 0.2), value: step)

      navigationRow
    }
    .padding(24)
    .frame(width: 460, height: 560)
    .task {
      hasScreenPermission = screenCapture.hasPermission()
    }
  }

  private var dismissRow: some View {
    HStack {
      Spacer()
      Button(action: complete) {
        Image(systemName: "xmark")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close voice onboarding")
    }
  }

  private var navigationRow: some View {
    HStack {
      Spacer()
      if step > 0 {
        Button("Back") {
          step -= 1
        }
        .controlSize(.large)
      }
      if step < 2 {
        Button("Next") {
          step += 1
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      } else {
        Button(onStartVoiceChat == nil ? "Done" : "Start voice chat") {
          complete()
          onStartVoiceChat?()
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func complete() {
    onboardingCompleted = true
    onDismiss()
  }

  private func requestScreenPermission() {
    hasScreenPermission = screenCapture.requestPermission()
  }
}

// MARK: - Step 1: Intro

private struct VoiceOnboardingIntroStep: View {
  let productName: String

  var body: some View {
    VStack(spacing: 28) {
      Text("Meet \(productName) Voice")
        .font(.system(size: 34, weight: .bold))
        .multilineTextAlignment(.center)
        .padding(.top, 24)

      VStack(spacing: 24) {
        VoiceOnboardingFeatureRow(
          icon: "rectangle.3.group",
          title: "Command your sessions",
          detail: "Launch agents, send prompts, and pick up work in any "
            + "session — hands free"
        )
        VoiceOnboardingFeatureRow(
          icon: "checkmark.shield",
          title: "Approve with your voice",
          detail: "Hear what a session wants to run and approve or deny it "
            + "without touching the keyboard"
        )
        VoiceOnboardingFeatureRow(
          icon: "bubble.left.and.bubble.right",
          title: "Hear the results",
          detail: "\(productName) announces when a session finishes and "
            + "reads its answer back to you"
        )
      }
      .padding(.horizontal, 8)
    }
  }
}

private struct VoiceOnboardingFeatureRow: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 6) {
      Label(title, systemImage: icon)
        .font(.headline)
        .foregroundStyle(.primary)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Step 2: Screenshots

private struct VoiceOnboardingScreenshotStep: View {
  @Binding var isEnabled: Bool
  let productName: String
  let hasPermission: Bool
  let onRequestPermission: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "camera.viewfinder")
        .font(.system(size: 44, weight: .medium))
        .foregroundStyle(.tint)
        .padding(.top, 16)

      Text("Bring your screen into the conversation")
        .font(.system(size: 28, weight: .bold))
        .multilineTextAlignment(.center)

      Text(
        "Screenshots let your coding agents see a display — or just an area "
          + "of it — when you ask about what's on screen. Works across all "
          + "connected monitors."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)

      Toggle(isOn: $isEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Use Screenshots")
            .font(.body.weight(.medium))
          Text("You can turn this off anytime in Settings")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.quaternary.opacity(0.5))
      )
      .onChange(of: isEnabled) { _, enabled in
        if enabled, !hasPermission {
          onRequestPermission()
        }
      }

      if isEnabled, !hasPermission {
        VStack(spacing: 6) {
          Label(
            "\(productName) needs Screen Recording access",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          Button("Open System Settings") {
            openScreenRecordingSettings()
          }
          .font(.caption)
        }
      }
    }
  }

  private func openScreenRecordingSettings() {
    let urlString = "x-apple.systempreferences:"
      + "com.apple.preference.security?Privacy_ScreenCapture"
    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }
}

// MARK: - Step 3: Voice picker

private struct VoiceOnboardingVoiceStep: View {
  @Binding var selectedVoiceId: String

  private var selectedIndex: Int {
    VoiceOption.all.firstIndex { $0.id == selectedVoiceId } ?? 0
  }

  private var selected: VoiceOption {
    VoiceOption.all[selectedIndex]
  }

  var body: some View {
    VStack(spacing: 16) {
      Text("Choose your voice")
        .font(.system(size: 28, weight: .bold))
        .padding(.top, 8)

      Text("You can change this anytime in Settings")
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack(spacing: 24) {
        VoiceCarouselArrow(systemImage: "chevron.left") {
          select(offset: -1)
        }

        Circle()
          .fill(
            LinearGradient(
              colors: selected.gradient,
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 140, height: 140)
          .shadow(color: selected.gradient[0].opacity(0.4), radius: 18)
          .animation(.easeInOut(duration: 0.2), value: selectedVoiceId)

        VoiceCarouselArrow(systemImage: "chevron.right") {
          select(offset: 1)
        }
      }
      .padding(.vertical, 12)

      Text(selected.title)
        .font(.title.bold())
      Text(selected.tagline)
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        ForEach(VoiceOption.all) { option in
          Circle()
            .fill(
              option.id == selectedVoiceId
                ? Color.accentColor
                : Color.secondary.opacity(0.35)
            )
            .frame(width: 7, height: 7)
            .onTapGesture {
              selectedVoiceId = option.id
            }
        }
      }
      .padding(.top, 4)
    }
  }

  private func select(offset: Int) {
    let count = VoiceOption.all.count
    let next = (selectedIndex + offset + count) % count
    selectedVoiceId = VoiceOption.all[next].id
  }
}

private struct VoiceCarouselArrow: View {
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
  }
}
