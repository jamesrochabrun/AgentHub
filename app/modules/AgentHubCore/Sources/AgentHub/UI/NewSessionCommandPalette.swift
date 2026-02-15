//
//  NewSessionCommandPalette.swift
//  AgentHub
//
//  Command palette modal for starting new sessions (inspired by VS Code)
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - NewSessionCommandPalette

public struct NewSessionCommandPalette: View {
  @Bindable var viewModel: MultiSessionLaunchViewModel
  let intelligenceViewModel: IntelligenceViewModel?
  let onDismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isDragging = false
  @State private var showingFilePicker = false

  public var body: some View {
    VStack(spacing: 0) {
      // Header with close button
      header

      Divider()

      // Content
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Repository selection
          repositorySelectionSection

          // Prompt input
          promptSection

          // Attached files
          if !viewModel.attachedFiles.isEmpty {
            attachedFilesSection
          }

          // Mode selection (Manual vs Smart)
          if viewModel.isSmartModeAvailable {
            modeSection
          }

          // Configuration based on mode
          if viewModel.launchMode == .manual {
            manualModeConfiguration
          } else {
            smartModeConfiguration
          }

          // Error display
          if let error = viewModel.launchError {
            errorSection(error)
          }
        }
        .padding(24)
      }
      .background(Color.surfaceCanvas)

      Divider()

      // Footer with actions
      footer
    }
    .frame(width: 550, height: 650)
    .background(cardBackground)
    .onDrop(
      of: [.fileURL, .png, .tiff, .image, .pdf],
      isTargeted: $isDragging
    ) { providers in
      handleDroppedFiles(providers)
      return true
    }
    .fileImporter(
      isPresented: $showingFilePicker,
      allowedContentTypes: [.image, .pdf, .plainText, .data],
      allowsMultipleSelection: true
    ) { result in
      handlePickedFiles(result)
    }
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      // Icon
      ZStack {
        Circle()
          .fill(Color.brandPrimary.opacity(0.15))
          .frame(width: 36, height: 36)
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(.brandPrimary)
      }

      // Title
      VStack(alignment: .leading, spacing: 2) {
        Text("New Session")
          .font(.system(size: 18, weight: .bold))
        Text("Configure and launch a new AI session")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
      }

      Spacer()

      // Close button
      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 20))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Close (Esc)")
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .background(Color.surfaceElevated)
  }

  // MARK: - Repository Selection

  private var repositorySelectionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel(title: "Repository", icon: "folder.fill")

      HStack(spacing: 12) {
        Button(action: { viewModel.selectRepository() }) {
          HStack(spacing: 8) {
            Image(systemName: viewModel.selectedRepository != nil ? "folder.fill" : "folder")
              .font(.system(size: 14))
              .foregroundColor(viewModel.selectedRepository != nil ? .brandPrimary : .secondary)

            Text(viewModel.selectedRepository?.name ?? "Choose repository...")
              .font(.system(size: 13, weight: .medium))
              .foregroundColor(viewModel.selectedRepository != nil ? .primary : .secondary)

            Spacer()

            Image(systemName: "chevron.down")
              .font(.system(size: 11))
              .foregroundColor(.secondary)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(colorScheme == .dark ? Color(white: 0.12) : Color.white)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(viewModel.selectedRepository != nil ? Color.brandPrimary.opacity(0.3) : Color.borderSubtle, lineWidth: 1.5)
          )
        }
        .buttonStyle(.plain)

        Button(action: { showingFilePicker = true }) {
          Image(systemName: "paperclip")
            .font(.system(size: 14))
            .foregroundColor(.secondary)
            .frame(width: 40, height: 44)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Attach files")
      }

      if let repo = viewModel.selectedRepository {
        Text(repo.path)
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.leading, 4)
      }
    }
  }

  // MARK: - Prompt Section

  private var promptSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel(title: "Prompt", icon: "text.bubble.fill", isOptional: viewModel.launchMode != .smart)

      ZStack(alignment: .topLeading) {
        if viewModel.sharedPrompt.isEmpty {
          Text(promptPlaceholder)
            .font(.system(size: 13))
            .foregroundColor(.secondary.opacity(0.6))
            .padding(.leading, 11)
            .padding(.top, 12)
        }
        TextEditor(text: $viewModel.sharedPrompt)
          .font(.system(size: 13))
          .scrollContentBackground(.hidden)
          .padding(6)
      }
      .frame(height: 100)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(colorScheme == .dark ? Color(white: 0.12) : Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.borderSubtle, lineWidth: 1)
      )
    }
  }

  private var promptPlaceholder: String {
    if viewModel.launchMode == .smart {
      return "Describe what you want to build..."
    } else {
      return "Optional: Describe the task for the AI agent..."
    }
  }

  // MARK: - Attached Files

  private var attachedFilesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel(title: "Attached Files", icon: "paperclip")

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(viewModel.attachedFiles) { file in
            fileChip(file)
          }
        }
      }
    }
  }

  private func fileChip(_ file: AttachedFile) -> some View {
    HStack(spacing: 6) {
      Image(systemName: file.icon)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
      Text(file.displayName)
        .font(.system(size: 12))
        .lineLimit(1)
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) {
          viewModel.removeAttachedFile(file)
        }
      }) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(Color.primary.opacity(0.08))
    )
    .overlay(
      Capsule()
        .strokeBorder(Color.borderSubtle, lineWidth: 1)
    )
  }

  // MARK: - Mode Section

  private var modeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel(title: "Launch Mode", icon: "sparkles")

      HStack(spacing: 12) {
        modeButton(mode: .manual, label: "Manual", icon: "gearshape")
        modeButton(mode: .smart, label: "Smart", icon: "sparkles", showsBeta: true)
      }
    }
  }

  private func modeButton(mode: LaunchMode, label: String, icon: String, showsBeta: Bool = false) -> some View {
    let isSelected = viewModel.launchMode == mode

    return Button(action: {
      withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.launchMode = mode
      }
    }) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 13))
        Text(label)
          .font(.system(size: 13, weight: .medium))
        if showsBeta {
          Text("Beta")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(isSelected ? .brandPrimary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              Capsule()
                .fill(isSelected ? Color.brandPrimary.opacity(0.15) : Color.primary.opacity(0.06))
            )
        }
        Spacer()
      }
      .foregroundColor(isSelected ? .primary : .secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(isSelected ? Color.brandPrimary.opacity(0.1) : Color.primary.opacity(0.04))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isSelected ? Color.brandPrimary.opacity(0.4) : Color.borderSubtle, lineWidth: 1.5)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Manual Mode Configuration

  private var manualModeConfiguration: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Worktree mode
      if viewModel.selectedRepository != nil {
        worktreeModeSection
      }

      // Provider selection
      providerSelectionSection

      // Progress (if launching worktree)
      if viewModel.isLaunching && viewModel.workMode == .worktree {
        progressSection
      }
    }
  }

  private var worktreeModeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel(title: "Work Mode", icon: "arrow.triangle.branch")

      HStack(spacing: 12) {
        workModeButton(mode: .local, label: "Local Branch")
        workModeButton(mode: .worktree, label: "New Worktree")
      }

      // Branch picker for worktree mode
      if viewModel.workMode == .worktree {
        VStack(alignment: .leading, spacing: 8) {
          Text("Base Branch")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)

          if viewModel.isLoadingBranches {
            HStack {
              ProgressView()
                .scaleEffect(0.7)
              Text("Loading branches...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
          } else {
            Picker("", selection: $viewModel.baseBranch) {
              Text("Current HEAD").tag(nil as RemoteBranch?)
              ForEach(viewModel.availableBranches) { branch in
                Text(branch.displayName).tag(branch as RemoteBranch?)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.03))
        )
      }
    }
  }

  private func workModeButton(mode: WorkMode, label: String) -> some View {
    let isSelected = viewModel.workMode == mode

    return Button(action: {
      withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.workMode = mode
      }
    }) {
      Text(label)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(isSelected ? .primary : .secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.primary : Color.borderSubtle, lineWidth: 1.5)
        )
    }
    .buttonStyle(.plain)
  }

  private var providerSelectionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel(title: "AI Agent", icon: "brain.head.profile")

      VStack(spacing: 8) {
        providerToggle(
          label: "Claude",
          mode: viewModel.claudeMode,
          onToggle: {
            withAnimation(.easeInOut(duration: 0.2)) {
              viewModel.claudeMode = viewModel.claudeMode.next
            }
          }
        )

        providerToggle(
          label: "Codex",
          isSelected: viewModel.isCodexSelected,
          onToggle: { viewModel.isCodexSelected.toggle() }
        )
      }
    }
  }

  @ViewBuilder
  private func providerToggle(
    label: String,
    mode: ClaudeMode? = nil,
    isSelected: Bool? = nil,
    onToggle: @escaping () -> Void
  ) -> some View {
    let selected = isSelected ?? (mode != .disabled)

    Button(action: onToggle) {
      HStack(spacing: 12) {
        ZStack {
          Circle()
            .fill(selected ? Color.brandPrimary.opacity(0.15) : Color.primary.opacity(0.06))
            .frame(width: 28, height: 28)
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundColor(selected ? .brandPrimary : .secondary)
        }

        Text(label)
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(selected ? .primary : .secondary)

        if let mode, mode == .enabledDangerously {
          Text("Dangerous")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              Capsule()
                .fill(Color.red.opacity(0.15))
            )
        }

        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(selected ? Color.primary.opacity(0.04) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(selected ? Color.brandPrimary.opacity(0.3) : Color.borderSubtle, lineWidth: 1.5)
      )
    }
    .buttonStyle(.plain)
  }

  private var progressSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      if viewModel.isClaudeSelected {
        progressRow(label: "Claude", progress: viewModel.claudeProgress)
      }
      if viewModel.isCodexSelected {
        progressRow(label: "Codex", progress: viewModel.codexProgress)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.03))
    )
  }

  private func progressRow(label: String, progress: WorktreeCreationProgress) -> some View {
    HStack(spacing: 12) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .frame(width: 50, alignment: .leading)

      if progress.isInProgress {
        ProgressView(value: progress.progressValue)
          .tint(.brandPrimary)
      } else {
        Image(systemName: progress.icon)
          .font(.system(size: 12))
          .foregroundColor(progressIconColor(for: progress))
      }

      Text(progress.statusMessage)
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .lineLimit(1)

      Spacer()

      if progress.isInProgress {
        Text("\(Int(progress.progressValue * 100))%")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .monospacedDigit()
      }
    }
  }

  // MARK: - Smart Mode Configuration

  private var smartModeConfiguration: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Provider selection for smart mode
      sectionLabel(title: "AI Agent", icon: "brain.head.profile")

      HStack(spacing: 8) {
        ForEach(SmartProvider.allCases, id: \.self) { provider in
          smartProviderButton(provider)
        }
      }

      // Smart phase views
      switch viewModel.smartPhase {
      case .planning:
        Text("Planning phase UI would go here")
          .font(.caption)
          .foregroundColor(.secondary)
      case .planReady:
        Text("Plan ready UI would go here")
          .font(.caption)
          .foregroundColor(.secondary)
      case .launching:
        Text("Launching UI would go here")
          .font(.caption)
          .foregroundColor(.secondary)
      case .idle:
        EmptyView()
      }
    }
  }

  private func smartProviderButton(_ provider: SmartProvider) -> some View {
    let isSelected = viewModel.smartProvider == provider

    return Button(action: {
      withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.smartProvider = provider
      }
    }) {
      Text(provider.rawValue)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(isSelected ? .primary : .secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.brandPrimary.opacity(0.1) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.brandPrimary.opacity(0.4) : Color.borderSubtle, lineWidth: 1.5)
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Error Section

  private func errorSection(_ error: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 14))
        .foregroundColor(.orange)
      Text(error)
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.orange.opacity(0.1))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
    )
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Button("Reset") {
        viewModel.reset()
      }
      .buttonStyle(.bordered)
      .disabled(viewModel.isLaunching)

      Spacer()

      Button(action: onDismiss) {
        Text("Cancel")
      }
      .buttonStyle(.bordered)
      .keyboardShortcut(.cancelAction)

      Button(action: {
        Task {
          await viewModel.launchSessions()
          // Auto-close on successful launch
          if viewModel.launchError == nil && !viewModel.isLaunching {
            onDismiss()
          }
        }
      }) {
        HStack(spacing: 6) {
          if viewModel.isLaunching {
            ProgressView()
              .scaleEffect(0.7)
          }
          Text(launchButtonTitle)
        }
        .frame(minWidth: 120)
      }
      .buttonStyle(.borderedProminent)
      .tint(.brandPrimary)
      .disabled(!viewModel.isValid || viewModel.isLaunching)
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .background(Color.surfaceElevated)
  }

  private var launchButtonTitle: String {
    if viewModel.launchMode == .smart {
      return "Launch Smart"
    }
    if viewModel.isLaunching {
      return viewModel.workMode == .worktree ? "Creating..." : "Launching..."
    }
    if viewModel.isClaudeSelected && viewModel.isCodexSelected {
      return "Launch Both"
    }
    if viewModel.isClaudeSelected {
      return "Launch Claude"
    }
    if viewModel.isCodexSelected {
      return "Launch Codex"
    }
    return "Launch Session"
  }

  // MARK: - Helpers

  private func sectionLabel(title: String, icon: String, isOptional: Bool = false) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundColor(.brandPrimary)
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.primary)
      if isOptional {
        Text("(Optional)")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
    }
  }

  private var cardBackground: Color {
    colorScheme == .dark ? Color(white: 0.10) : Color.white
  }

  // MARK: - File Handling (copied from original)

  private func handleDroppedFiles(_ providers: [NSItemProvider]) {
    // Same implementation as MultiSessionLaunchView
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
          guard let url = url, error == nil else { return }
          Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.2)) {
              viewModel.addAttachedFile(url)
            }
          }
        }
      }
    }
  }

  private func handlePickedFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      withAnimation(.easeInOut(duration: 0.2)) {
        for url in urls {
          viewModel.addAttachedFile(url)
        }
      }
    case .failure(let error):
      print("File picker error: \(error.localizedDescription)")
    }
  }

  private func progressIconColor(for progress: WorktreeCreationProgress) -> Color {
    switch progress {
    case .completed:
      return .green
    case .failed:
      return .red
    default:
      return .secondary
    }
  }
}
