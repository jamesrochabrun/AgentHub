//
//  MultiSessionLaunchView.swift
//  AgentHub
//
//  Always-visible session launcher for starting Claude, Codex, or both
//  with a shared prompt. Supports local mode and worktree mode.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - MultiSessionLaunchView

public struct MultiSessionLaunchView: View {
  @Bindable var viewModel: MultiSessionLaunchViewModel

  @Environment(\.colorScheme) private var colorScheme
  @State private var isExpanded = false
  @State private var isDragging = false
  @State private var showingFilePicker = false

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      formHeader

      if isExpanded {
        Divider()

        repositorySection

        promptEditor

        if !viewModel.attachedFiles.isEmpty {
          attachedFilesSection
        }

        attachmentRow

        if viewModel.selectedRepository != nil {
          workModeRow
        }

        providerPills

        if viewModel.isLaunching && viewModel.workMode == .worktree {
          progressSection
        }

        if let error = viewModel.launchError {
          errorView(error)
        }

        Divider()

        actionButtons
      }
    }
    .padding(DesignTokens.Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(isDragging ? Color.accentColor : Color.borderSubtle, lineWidth: isDragging ? 2 : 1)
    )
    .onDrop(
      of: [.fileURL, .png, .tiff, .image, .pdf],
      isTargeted: isExpanded ? $isDragging : .constant(false)
    ) { providers in
      guard isExpanded else { return false }
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
    .onChange(of: viewModel.isLaunching) { wasLaunching, isLaunching in
      if wasLaunching && !isLaunching {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded = false
        }
      }
    }
  }

  // MARK: - Header

  private var formHeader: some View {
    HStack {
      Text("Start Project")
        .font(.system(size: 14, weight: .bold, design: .monospaced))
      Spacer()
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      }) {
        Image(systemName: isExpanded ? "minus.circle" : "plus.circle")
          .font(.system(size: 16))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.2)) {
        isExpanded.toggle()
      }
    }
    .padding(.top, 6)
    .padding(.bottom, 6)
    .padding(.leading, 6)
  }

  // MARK: - Repository Section

  private var repositorySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: { viewModel.selectRepository() }) {
        HStack(spacing: 6) {
          Image(systemName: "folder")
            .font(.system(size: 11))
          Text(viewModel.selectedRepository?.name ?? "Select repository")
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          Capsule()
            .fill(viewModel.selectedRepository != nil
                  ? Color.primary.opacity(0.1)
                  : Color.primary.opacity(0.05))
        )
        .overlay(
          Capsule()
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)

      if let repo = viewModel.selectedRepository {
        Text(repo.path)
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  // MARK: - Prompt Editor

  private var promptEditor: some View {
    ZStack(alignment: .topLeading) {
      if viewModel.sharedPrompt.isEmpty {
        Text(promptPlaceholder)
          .font(.system(size: 12))
          .foregroundColor(.secondary.opacity(0.6))
          .padding(.leading, 7)
          .padding(.top, 4)
      }
      TextEditor(text: $viewModel.sharedPrompt)
        .font(.system(size: 12))
        .scrollContentBackground(.hidden)
        .padding(2)
    }
    .frame(minHeight: 60, maxHeight: 120)
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  private var promptPlaceholder: String {
    if viewModel.claudeMode == .enabledDangerously && !viewModel.isCodexSelected {
      return "Takes all actions without asking..."
    } else if viewModel.isClaudeSelected && viewModel.isCodexSelected {
      return "Enter prompt for both sessions..."
    } else if viewModel.isClaudeSelected {
      return "Enter prompt for Claude session..."
    } else if viewModel.isCodexSelected {
      return "Enter prompt for Codex session..."
    } else {
      return "Select a provider..."
    }
  }

  // MARK: - Attachments

  private var attachedFilesSection: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(viewModel.attachedFiles) { file in
          HStack(spacing: 4) {
            Image(systemName: file.icon)
              .font(.system(size: 9))
            Text(file.displayName)
              .font(.system(size: 10))
              .lineLimit(1)
            Button(action: { viewModel.removeAttachedFile(file) }) {
              Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            Capsule()
              .fill(Color.primary.opacity(0.08))
          )
          .overlay(
            Capsule()
              .stroke(Color.borderSubtle, lineWidth: 1)
          )
        }
      }
    }
  }

  private var attachmentRow: some View {
    HStack {
      Button(action: { showingFilePicker = true }) {
        HStack(spacing: 4) {
          Image(systemName: "paperclip")
            .font(.system(size: 11))
          Text("Attach Files")
            .font(.system(size: 11))
        }
        .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      Spacer()
    }
  }

  // MARK: - File Handling

  private func handleDroppedFiles(_ providers: [NSItemProvider]) {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
          guard let url = url, error == nil else { return }
          Task { @MainActor in
            viewModel.addAttachedFile(url)
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
        _ = provider.loadDataRepresentation(for: .png) { data, error in
          guard let data = data, error == nil else { return }
          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("screenshot_\(UUID().uuidString).png")
            do {
              try data.write(to: tempURL)
              viewModel.addAttachedFile(tempURL, isTemporary: true)
            } catch {
              print("Failed to save dropped screenshot: \(error)")
            }
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
        _ = provider.loadDataRepresentation(for: .tiff) { data, error in
          guard let data = data, error == nil else { return }
          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("screenshot_\(UUID().uuidString).tiff")
            do {
              try data.write(to: tempURL)
              viewModel.addAttachedFile(tempURL, isTemporary: true)
            } catch {
              print("Failed to save dropped screenshot: \(error)")
            }
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        _ = provider.loadDataRepresentation(for: .image) { data, error in
          guard let data = data, error == nil else { return }
          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("dropped_image_\(UUID().uuidString).png")
            do {
              try data.write(to: tempURL)
              viewModel.addAttachedFile(tempURL, isTemporary: true)
            } catch {
              print("Failed to save dropped image: \(error)")
            }
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
        _ = provider.loadDataRepresentation(for: .pdf) { data, error in
          guard let data = data, error == nil else { return }
          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("dropped_document_\(UUID().uuidString).pdf")
            do {
              try data.write(to: tempURL)
              viewModel.addAttachedFile(tempURL, isTemporary: true)
            } catch {
              print("Failed to save dropped PDF: \(error)")
            }
          }
        }
      }
    }
  }

  private func handlePickedFiles(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      for url in urls {
        viewModel.addAttachedFile(url)
      }
    case .failure(let error):
      print("File picker error: \(error.localizedDescription)")
    }
  }

  // MARK: - Work Mode Row

  private var workModeRow: some View {
    ViewThatFits(in: .horizontal) {
      // Primary: horizontal layout
      HStack(spacing: 0) {
        HStack(spacing: 12) {
          workModeButton(mode: .local, label: "Local")
          workModeButton(mode: .worktree, label: "Worktree")
        }
        Spacer()
        branchInfoView
      }
      // Fallback: vertical layout when horizontal doesn't fit
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          workModeButton(mode: .local, label: "Local")
          workModeButton(mode: .worktree, label: "Worktree")
        }
        branchInfoView
      }
    }
  }

  private func workModeButton(mode: WorkMode, label: String) -> some View {
    Button(action: {
      withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.workMode = mode
      }
    }) {
      Text(label)
        .font(.system(size: 11, weight: viewModel.workMode == mode ? .bold : .regular))
        .foregroundColor(viewModel.workMode == mode ? .primary : .secondary.opacity(0.6))
        .fixedSize()
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var branchInfoView: some View {
    switch viewModel.workMode {
    case .local:
      HStack(spacing: 4) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
        if viewModel.isLoadingCurrentBranch {
          ProgressView()
            .scaleEffect(0.5)
            .frame(width: 12, height: 12)
        } else {
          Text(viewModel.currentBranchName.isEmpty ? "—" : viewModel.currentBranchName)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }
    case .worktree:
      if viewModel.isLoadingBranches {
        HStack(spacing: 4) {
          ProgressView()
            .scaleEffect(0.5)
            .frame(width: 12, height: 12)
          Text("Loading...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      } else {
        Picker("Base", selection: $viewModel.baseBranch) {
          Text("Current HEAD").tag(nil as RemoteBranch?)
          ForEach(viewModel.availableBranches) { branch in
            Text(branch.displayName).tag(branch as RemoteBranch?)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
    }
  }

  // MARK: - Provider Pills

  private var providerPills: some View {
    HStack(spacing: 8) {
      claudePill
      providerPill(
        label: "Codex",
        isSelected: $viewModel.isCodexSelected
      )
      Spacer()
    }
  }

  private var claudePill: some View {
    Button(action: {
      withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.claudeMode = viewModel.claudeMode.next
      }
    }) {
      Text(viewModel.claudeMode.label)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(claudePillForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
          Capsule()
            .fill(claudePillBackground)
        )
    }
    .buttonStyle(.plain)
  }

  private var claudePillForeground: Color {
    switch viewModel.claudeMode {
    case .disabled:
      return .secondary
    case .enabled:
      return colorScheme == .dark ? .black : .white
    case .enabledDangerously:
      return Color(nsColor: NSColor(srgbRed: 0.45, green: 0.1, blue: 0.1, alpha: 1))
    }
  }

  private var claudePillBackground: Color {
    switch viewModel.claudeMode {
    case .disabled:
      return Color.primary.opacity(0.06)
    case .enabled:
      return colorScheme == .dark ? Color.white : Color.black
    case .enabledDangerously:
      return colorScheme == .dark
        ? Color(nsColor: NSColor(srgbRed: 0.96, green: 0.64, blue: 0.64, alpha: 1))
        : Color(nsColor: NSColor(srgbRed: 0.91, green: 0.54, blue: 0.54, alpha: 1))
    }
  }

  private func providerPill(label: String, isSelected: Binding<Bool>) -> some View {
    Button(action: { isSelected.wrappedValue.toggle() }) {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(isSelected.wrappedValue ? (colorScheme == .dark ? .black : .white) : .secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
          Capsule()
            .fill(isSelected.wrappedValue ? (colorScheme == .dark ? Color.white : Color.black) : Color.primary.opacity(0.06))
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Progress

  private var progressSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if viewModel.isClaudeSelected {
        progressRow(label: "Claude", progress: viewModel.claudeProgress)
      }
      if viewModel.isCodexSelected {
        progressRow(label: "Codex", progress: viewModel.codexProgress)
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.primary.opacity(0.03))
    )
  }

  private func progressRow(label: String, progress: WorktreeCreationProgress) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .frame(width: 40, alignment: .trailing)

      if progress.isInProgress {
        ProgressView(value: progress.progressValue)
          .tint(.primary)
      } else {
        Image(systemName: progress.icon)
          .font(.caption)
          .foregroundColor(progressIconColor(for: progress))
      }

      Text(progress.statusMessage)
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)

      Spacer()

      if progress.isInProgress {
        Text("\(Int(progress.progressValue * 100))%")
          .font(.caption2)
          .foregroundColor(.secondary)
          .monospacedDigit()
      }
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

  // MARK: - Error

  private func errorView(_ error: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundColor(.orange)
      Text(error)
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(3)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.orange.opacity(0.1))
    )
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack {
      Button("Reset") {
        viewModel.reset()
      }
      .disabled(viewModel.isLaunching)

      Spacer()

      Button(action: {
        Task {
          await viewModel.launchSessions()
        }
      }) {
        HStack(spacing: 6) {
          if viewModel.isLaunching {
            ProgressView()
              .scaleEffect(0.7)
          }
          Text(launchButtonTitle)
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(.primary)
      .disabled(!viewModel.isValid || viewModel.isLaunching)
    }
  }

  private var launchButtonTitle: String {
    if viewModel.isLaunching {
      return viewModel.workMode == .worktree ? "Generating worktrees..." : "Launching..."
    }
    return "Launch"
  }
}
