//
//  ArtifactSidePanelView.swift
//  AgentHub
//
//  Embedded side panel that renders the Claude artifacts an agent published
//  during a session (parsed from the session JSONL into
//  `SessionMonitorState.detectedArtifacts`).
//

import SwiftUI

// MARK: - ArtifactSignInBanner

/// Shown when the web view lands on a sign-in page instead of the artifact.
/// The sign-in is Anthropic's, not ours — this says so, so a login wall inside
/// AgentHub doesn't read as an AgentHub bug or an AgentHub credential prompt.
///
/// Deliberately offers no "open in browser" escape: a browser session is a
/// different cookie jar, so signing in there does nothing for this panel and
/// would just send the user around a loop.
private struct ArtifactSignInBanner: View {
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "lock")
        .foregroundStyle(Color.brandPrimary)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Sign in below to view this artifact")
          .font(.caption.weight(.semibold))
        Text("Artifacts are hosted by Anthropic and private to your account. This is Anthropic's standard sign-in page — AgentHub doesn't handle it. Signing in in your browser doesn't carry over, so sign in here; you only need to do it once.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.brandPrimary.opacity(0.10))
  }
}

// MARK: - ArtifactSidePanelView

/// Side panel host for agent-published artifact pages. Reads the live list from
/// the session's monitor state, so a republish updates the open panel.
struct ArtifactSidePanelView: View {
  let artifacts: [ClaudeArtifact]
  let onDismiss: () -> Void
  var isEmbedded = false
  let isExpanded: Bool
  var onToggleExpanded: (() -> Void)?

  @State private var selectedArtifactID: String?
  @State private var manualReloadCount = 0
  @State private var isLoading = false
  @State private var failureMessage: String?
  @State private var currentURL: URL?
  @Environment(\.openURL) private var openURL

  private var isShowingSignIn: Bool {
    currentURL.map(ClaudeArtifactURLDetector.isSignInURL) ?? false
  }

  private var artifactIDs: [String] {
    artifacts.map(\.id)
  }

  /// Identity of what should currently be on screen: switching artifacts, the
  /// agent republishing the open one, and Reload all reload the page.
  private var reloadToken: String {
    guard let selectedArtifact else { return "none" }
    return "\(selectedArtifact.id)#\(selectedArtifact.revision)#\(manualReloadCount)"
  }

  /// Newest artifact by default — the one the agent just published.
  private var selectedArtifact: ClaudeArtifact? {
    guard let selectedArtifactID else { return artifacts.last }
    return artifacts.first { $0.id == selectedArtifactID } ?? artifacts.last
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      if let selectedArtifact {
        content(for: selectedArtifact)
      } else {
        emptyState
      }
    }
    .frame(
      minWidth: 300, idealWidth: .infinity, maxWidth: .infinity,
      minHeight: 300, idealHeight: .infinity, maxHeight: .infinity
    )
    .onAppear {
      selectedArtifactID = selectedArtifactID ?? artifacts.last?.id
    }
    .onChange(of: artifactIDs) { previousIDs, currentIDs in
      reconcileSelection(previousIDs: previousIDs, currentIDs: currentIDs)
    }
    .onChange(of: reloadToken) {
      failureMessage = nil
      currentURL = nil
    }
    .onKeyPress(.escape) {
      guard !isEmbedded else { return .handled }
      onDismiss()
      return .handled
    }
  }

  // MARK: - Content

  @ViewBuilder
  private func content(for artifact: ClaudeArtifact) -> some View {
    if let failureMessage {
      failureState(for: artifact, message: failureMessage)
    } else {
      VStack(spacing: 0) {
        if isShowingSignIn {
          ArtifactSignInBanner()
          Divider()
        }

        ArtifactWebView(
          url: artifact.url,
          reloadToken: reloadToken,
          onLoadingChange: { isLoading = $0 },
          onFailure: { failureMessage = $0 },
          onPageChange: { currentURL = $0 }
        )
        .overlay(alignment: .top) {
          if isLoading {
            ProgressView()
              .progressViewStyle(.linear)
              .frame(height: 2)
              .accessibilityLabel("Loading artifact")
          }
        }
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No Artifacts",
      systemImage: "sparkles.rectangle.stack",
      description: Text("This session has not published an artifact yet.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failureState(for artifact: ClaudeArtifact, message: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      ContentUnavailableView(
        "Couldn't Load Artifact",
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )

      HStack(spacing: DesignTokens.Spacing.sm) {
        Button("Try Again", action: reload)
        Button("Open in Browser") { openURL(artifact.url) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles.rectangle.stack")
        .foregroundStyle(Color.brandPrimary)
        .accessibilityHidden(true)

      Text("Artifact")
        .font(.headline)

      if artifacts.count == 1, let selectedArtifact {
        Text(selectedArtifact.displayTitle)
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 12)

      if artifacts.count > 1 {
        Picker("Artifact", selection: Binding(
          get: { selectedArtifact?.id },
          set: { selectedArtifactID = $0 }
        )) {
          ForEach(Array(artifacts.enumerated()), id: \.element.id) { index, artifact in
            Text(pickerLabel(for: artifact, at: index))
              .tag(Optional(artifact.id))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .accessibilityLabel("Select artifact")
      }

      Button(action: reload) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(selectedArtifact == nil)
      .accessibilityLabel("Reload artifact")
      .help("Reload artifact")

      if let selectedArtifact {
        Button {
          openURL(selectedArtifact.url)
        } label: {
          Image(systemName: "safari")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open artifact in browser")
        .help("Open in browser")
      }

      if let onToggleExpanded {
        Button(action: onToggleExpanded) {
          Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse artifact" : "Expand artifact to full width")
        .help(isExpanded ? "Collapse artifact (⌘⇧O)" : "Expand artifact to full width (⌘⇧O)")
      }

      closeButton
    }
    .overlay {
      if let onToggleExpanded {
        Button("") { onToggleExpanded() }
          .keyboardShortcut("o", modifiers: [.command, .shift])
          .hidden()
          .frame(width: 0, height: 0)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var closeButton: some View {
    if isEmbedded {
      Button("Close", action: onDismiss)
    } else {
      Button("Close", action: onDismiss)
        .keyboardShortcut(.cancelAction)
    }
  }

  // MARK: - Actions

  private func reload() {
    failureMessage = nil
    manualReloadCount += 1
  }

  /// Picker label, disambiguated by position when artifacts share a title
  /// (successive publishes of differently-named files can still collide).
  private func pickerLabel(for artifact: ClaudeArtifact, at index: Int) -> String {
    let sharesTitle = artifacts.filter { $0.displayTitle == artifact.displayTitle }.count > 1
    return sharesTitle ? "\(artifact.displayTitle) \(index + 1)" : artifact.displayTitle
  }

  /// Follows the agent: a newly published artifact takes the selection, an
  /// existing selection survives reordering, and a vanished one falls back to
  /// the newest.
  private func reconcileSelection(previousIDs: [String], currentIDs: [String]) {
    let added = Set(currentIDs).subtracting(previousIDs)
    if let newest = currentIDs.last(where: { added.contains($0) }) {
      selectedArtifactID = newest
      failureMessage = nil
      return
    }
    if let selectedArtifactID, currentIDs.contains(selectedArtifactID) {
      return
    }
    selectedArtifactID = currentIDs.last
  }
}
