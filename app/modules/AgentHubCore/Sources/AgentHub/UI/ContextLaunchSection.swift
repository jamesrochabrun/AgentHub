//
//  ContextLaunchSection.swift
//  AgentHub
//
//  Launcher row for curated context: shows the attached profile (or ad-hoc
//  curation) as a removable chip with an approximate token cost, and opens the
//  Context Builder. Rendered in both compact and full launcher styles.
//

import SwiftUI

struct ContextLaunchSection: View {
  @Bindable var viewModel: MultiSessionLaunchViewModel
  @State private var showingContextBuilder = false
  @Environment(\.agentHub) private var agentHub

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      headerRow
      if viewModel.activeContextSelection != nil {
        chipRow
          .transition(.scale(scale: 0.92).combined(with: .opacity))
      }
      if !viewModel.contextMissingPaths.isEmpty {
        missingWarning
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: viewModel.attachedContextProfile)
    .animation(.easeInOut(duration: 0.2), value: viewModel.pendingContextSelection)
    .animation(.easeInOut(duration: 0.2), value: viewModel.contextMissingPaths)
    .task(id: viewModel.selectedRepository?.path) {
      await viewModel.loadDefaultContextProfile()
      await viewModel.refreshContextSummary()
    }
    .sheet(isPresented: $showingContextBuilder) {
      contextBuilderSheet
    }
  }

  // MARK: - Rows

  private var headerRow: some View {
    HStack(spacing: 8) {
      Text("Context")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
      Spacer()
      Button {
        showingContextBuilder = true
      } label: {
        Label(
          viewModel.activeContextSelection == nil ? "Add Context…" : "Edit…",
          systemImage: "square.stack.3d.up"
        )
        .font(.secondaryCaption)
      }
      .buttonStyle(.plain)
      .foregroundColor(.secondary)
      .help("Choose exactly which files the agent starts with — pick from saved context sets or curate ad hoc — and preview the assembled block")
    }
  }

  private var chipRow: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: "square.stack.3d.up")
          .font(.system(size: 9))
        Text(chipTitle)
          .font(.secondaryCaption)
          .lineLimit(1)
        if viewModel.attachedContextProfile?.isDefault == true && viewModel.pendingContextSelection == nil {
          Text("default")
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.brandPrimary.opacity(0.15)))
            .foregroundColor(.brandPrimary)
        }
        if let tokens = viewModel.contextSummaryTokens {
          Text("~\(SessionMonitorState.formatTokenCount(tokens)) tokens")
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
            .help("Approximate — estimated from file size (bytes ÷ 4 with a safety margin), not a real tokenizer.")
        }
        Button(action: { viewModel.removeAttachedContextProfile() }) {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Launch without curated context")
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Capsule().fill(Color.primary.opacity(0.08)))
      .overlay(Capsule().stroke(Color.borderSubtle, lineWidth: 1))
      Spacer(minLength: 0)
    }
  }

  private var chipTitle: String {
    if let selection = viewModel.pendingContextSelection {
      let count = selection.files.count + selection.externalPaths.count + selection.textSnippets.count
      return "Ad-hoc context (\(count) item\(count == 1 ? "" : "s"))"
    }
    if let profile = viewModel.attachedContextProfile {
      let selection = profile.selection
      let count = selection.files.count + selection.externalPaths.count + selection.textSnippets.count
      return "\(profile.name) (\(count) items)"
    }
    return ""
  }

  private var missingWarning: some View {
    Label(
      "\(viewModel.contextMissingPaths.count) selected file\(viewModel.contextMissingPaths.count == 1 ? " could" : "s could") not be found and will be skipped",
      systemImage: "exclamationmark.triangle"
    )
    .font(.secondaryCaption)
    .foregroundColor(.orange)
  }

  // MARK: - Builder Sheet

  /// The configured default model for the selected provider, so the builder's
  /// window percentage reflects that model's real context window.
  private var configuredModelIdentifier: String? {
    let provider = viewModel.isCodexSelected && !viewModel.isClaudeSelected ? "codex" : "claude"
    let model = agentHub?.metadataStore?.getAIConfigSync(for: provider)?.defaultModel
    return (model?.isEmpty == false) ? model : nil
  }

  @ViewBuilder
  private var contextBuilderSheet: some View {
    if let repo = viewModel.selectedRepository {
      ContextBuilderView(
        viewModel: ContextBuilderViewModel(
          projectPath: repo.path,
          initialSelection: viewModel.activeContextSelection,
          sourceProfile: viewModel.pendingContextSelection == nil ? viewModel.attachedContextProfile : nil,
          modelIdentifier: configuredModelIdentifier,
          fileLoader: viewModel.contextFileLoader,
          estimator: viewModel.contextTokenEstimator,
          profileService: viewModel.contextProfileService
        ),
        mode: .launch { selection, unmodifiedProfile in
          if let unmodifiedProfile {
            viewModel.attachContextProfile(unmodifiedProfile)
          } else {
            viewModel.applyCuratedContext(selection)
          }
          Task { await viewModel.refreshContextSummary() }
        },
        onDismiss: { showingContextBuilder = false }
      )
    }
  }
}
