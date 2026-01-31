//
//  MonitoringCardView.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

import ClaudeCodeSDK
import SwiftUI
import UniformTypeIdentifiers

// MARK: - CodeChangesSheetItem

/// Identifiable wrapper for sheet(item:) pattern - captures all data needed for the sheet
private struct CodeChangesSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let codeChangesState: CodeChangesState
}

// MARK: - GitDiffSheetItem

/// Identifiable wrapper for git diff sheet - captures session and project path
private struct GitDiffSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
}

// MARK: - PlanSheetItem

/// Identifiable wrapper for plan sheet - captures session and plan state
private struct PlanSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let planState: PlanState
}

// MARK: - PendingChangesSheetItem

/// Identifiable wrapper for pending changes preview sheet
private struct PendingChangesSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let pendingToolUse: PendingToolUse
}

// MARK: - MonitoringCardView

/// Card view for displaying a monitored session in the monitoring panel
public struct MonitoringCardView: View {
  let session: CLISession
  let state: SessionMonitorState?
  let codeChangesState: CodeChangesState?
  let planState: PlanState?
  let claudeClient: (any ClaudeCode)?
  let showTerminal: Bool
  let initialPrompt: String?
  let terminalKey: String?  // Key for terminal storage (session ID or "pending-{pendingId}")
  let viewModel: CLISessionsViewModel?
  let onToggleTerminal: (Bool) -> Void
  let onStopMonitoring: () -> Void
  let onConnect: () -> Void
  let onCopySessionId: () -> Void
  let onOpenSessionFile: () -> Void
  let onRefreshTerminal: () -> Void
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?
  let onPromptConsumed: (() -> Void)?
  let isMaximized: Bool
  let onToggleMaximize: () -> Void

  @State private var codeChangesSheetItem: CodeChangesSheetItem?
  @State private var gitDiffSheetItem: GitDiffSheetItem?
  @State private var planSheetItem: PlanSheetItem?
  @State private var pendingChangesSheetItem: PendingChangesSheetItem?
  @State private var isDragging = false
  @State private var showingActionsPopover = false
  @State private var showingFilePicker = false
  @State private var showingNameSheet = false
  @Environment(\.colorScheme) private var colorScheme

  public init(
    session: CLISession,
    state: SessionMonitorState?,
    codeChangesState: CodeChangesState? = nil,
    planState: PlanState? = nil,
    claudeClient: (any ClaudeCode)? = nil,
    showTerminal: Bool = false,
    initialPrompt: String? = nil,
    terminalKey: String? = nil,
    viewModel: CLISessionsViewModel? = nil,
    onToggleTerminal: @escaping (Bool) -> Void,
    onStopMonitoring: @escaping () -> Void,
    onConnect: @escaping () -> Void,
    onCopySessionId: @escaping () -> Void,
    onOpenSessionFile: @escaping () -> Void,
    onRefreshTerminal: @escaping () -> Void,
    onInlineRequestSubmit: ((String, CLISession) -> Void)? = nil,
    onPromptConsumed: (() -> Void)? = nil,
    isMaximized: Bool = false,
    onToggleMaximize: @escaping () -> Void = {}
  ) {
    self.session = session
    self.state = state
    self.codeChangesState = codeChangesState
    self.planState = planState
    self.claudeClient = claudeClient
    self.showTerminal = showTerminal
    self.initialPrompt = initialPrompt
    self.terminalKey = terminalKey
    self.viewModel = viewModel
    self.onToggleTerminal = onToggleTerminal
    self.onStopMonitoring = onStopMonitoring
    self.onConnect = onConnect
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.onRefreshTerminal = onRefreshTerminal
    self.onInlineRequestSubmit = onInlineRequestSubmit
    self.onPromptConsumed = onPromptConsumed
    self.isMaximized = isMaximized
    self.onToggleMaximize = onToggleMaximize
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with session info and actions
      header
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      Divider()

      // Path row with folder, branch, and diff button
      pathRow
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      // Context bar (only in monitor/list mode, not terminal mode)
      if !showTerminal, let state = state, state.inputTokens > 0 {
        Divider()

        ContextWindowBar(
          percentage: state.contextWindowUsagePercentage,
          formattedUsage: state.formattedContextUsage,
          model: state.model
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }

      // Recent activity (with status) or terminal
      Divider()

      monitorContent
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .background(colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.92))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(
      color: Color.blue.opacity(isDragging ? 0.875 : 0),
      radius: isDragging ? 12 : 0
    )
    .animation(.easeInOut(duration: 0.2), value: isDragging)
    .onDrop(
      of: [.fileURL, .png, .tiff, .image, .pdf],
      isTargeted: showTerminal ? $isDragging : .constant(false)
    ) { providers in
      guard showTerminal else { return false }
      handleDroppedFiles(providers)
      return true
    }
    .sheet(item: $codeChangesSheetItem) { item in
      CodeChangesView(
        session: item.session,
        codeChangesState: item.codeChangesState,
        onDismiss: { codeChangesSheetItem = nil },
        claudeClient: claudeClient
      )
    }
    .sheet(item: $gitDiffSheetItem) { item in
      GitDiffView(
        session: item.session,
        projectPath: item.projectPath,
        onDismiss: { gitDiffSheetItem = nil },
        claudeClient: claudeClient,
        onInlineRequestSubmit: onInlineRequestSubmit
      )
    }
    .sheet(item: $planSheetItem) { item in
      PlanView(
        session: item.session,
        planState: item.planState,
        onDismiss: { planSheetItem = nil }
      )
    }
    .sheet(item: $pendingChangesSheetItem) { item in
      PendingChangesView(
        session: item.session,
        pendingToolUse: item.pendingToolUse,
        claudeClient: claudeClient,
        onDismiss: { pendingChangesSheetItem = nil },
        onApprovalResponse: { response, session in
          viewModel?.showTerminalWithPrompt(for: session, prompt: response)
        }
      )
    }
    .sheet(isPresented: $showingNameSheet) {
      NameSessionSheet(
        session: session,
        currentName: viewModel?.sessionCustomNames[session.id],
        onSave: { name in
          viewModel?.setCustomName(name, for: session)
        },
        onDismiss: { showingNameSheet = false }
      )
    }
    .fileImporter(
      isPresented: $showingFilePicker,
      allowedContentTypes: [.image, .pdf, .plainText, .data],
      allowsMultipleSelection: true
    ) { result in
      handlePickedFiles(result)
    }
  }

  private var isHighlighted: Bool {
    guard let state = state else { return false }
    switch state.status {
    case .awaitingApproval, .executingTool, .thinking:
      return true
    default:
      return false
    }
  }

  // MARK: - Drag and Drop

  /// Handles dropped file providers by extracting paths and typing them into terminal
  private func handleDroppedFiles(_ providers: [NSItemProvider]) {
    guard showTerminal, let key = terminalKey, let viewModel = viewModel else { return }

    for provider in providers {
      // Handle file URLs (files dragged from Finder)
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
          guard let url = url, error == nil else { return }

          Task { @MainActor in
            let path = url.path
            let quotedPath = path.contains(" ") ? "\"\(path)\"" : path
            viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
          }
        }
      }
      // Handle PNG data (screenshots)
      else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
        _ = provider.loadDataRepresentation(for: .png) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("screenshot_\(UUID().uuidString).png")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped screenshot: \(error)")
            }
          }
        }
      }
      // Handle TIFF data (another screenshot format)
      else if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
        _ = provider.loadDataRepresentation(for: .tiff) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("screenshot_\(UUID().uuidString).tiff")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped screenshot: \(error)")
            }
          }
        }
      }
      // Handle generic image data
      else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        _ = provider.loadDataRepresentation(for: .image) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("dropped_image_\(UUID().uuidString).png")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped image: \(error)")
            }
          }
        }
      }
      // Handle PDF data (documents dragged from Preview or other apps)
      else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
        _ = provider.loadDataRepresentation(for: .pdf) { data, error in
          guard let data = data, error == nil else { return }

          Task { @MainActor in
            let tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("dropped_document_\(UUID().uuidString).pdf")
            do {
              try data.write(to: tempURL)
              let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
              viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
            } catch {
              print("Failed to save dropped PDF: \(error)")
            }
          }
        }
      }
    }
  }

  // MARK: - File Picker

  /// Handles files selected from the file picker by typing their paths into terminal
  private func handlePickedFiles(_ result: Result<[URL], Error>) {
    guard showTerminal, let key = terminalKey, let viewModel = viewModel else { return }

    switch result {
    case .success(let urls):
      for url in urls {
        let path = url.path
        let quotedPath = path.contains(" ") ? "\"\(path)\"" : path
        viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
      }
    case .failure(let error):
      print("File picker error: \(error.localizedDescription)")
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      // Activity indicator circle - shows when session is working
      Circle()
        .fill(isHighlighted ? Color.brandPrimary : .gray.opacity(0.3))
        .frame(width: 10, height: 10)
        .shadow(color: isHighlighted ? Color.brandPrimary.opacity(0.6) : .clear, radius: 4)

      // Session label - show custom name, slug, or default ID
      if let customName = viewModel?.sessionCustomNames[session.id] {
        Text(customName)
          .font(.subheadline)
          .fontWeight(.medium)
      } else if let slug = session.slug {
        // Show slug and short ID (matching CLISessionRow format)
        HStack(spacing: 4) {
          Text(slug)
            .font(.system(.subheadline, design: .monospaced))
            .fontWeight(.semibold)
          Text("•")
            .font(.caption)
            .foregroundColor(.secondary)
          Text(session.shortId)
            .font(.system(.subheadline, design: .monospaced))
            .fontWeight(.semibold)
        }
      } else {
        HStack(spacing: 4) {
          Text("Session:")
            .font(.subheadline)
            .foregroundColor(.secondary)
          Text(session.shortId)
            .font(.system(.subheadline, design: .monospaced))
            .fontWeight(.bold)
        }
      }

      Spacer()

      // Terminal/List segmented control (hidden when maximized)
      if !isMaximized {
        HStack(spacing: 4) {
          // Terminal button (left - default)
          Button(action: { withAnimation(.easeInOut(duration: 0.2)) { onToggleTerminal(true) } }) {
            Image(systemName: "terminal")
              .font(.caption)
              .frame(width: 28, height: 22)
              .foregroundColor(showTerminal ? .brandPrimary : .secondary)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          // List/Monitor button (right)
          Button(action: { withAnimation(.easeInOut(duration: 0.2)) { onToggleTerminal(false) } }) {
            Image(systemName: "list.bullet")
              .font(.caption)
              .frame(width: 28, height: 22)
              .foregroundColor(!showTerminal ? .brandPrimary : .secondary)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.2), value: showTerminal)
      }

      // Maximize/Minimize button
      Button(action: onToggleMaximize) {
        Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(width: 24, height: 24)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .buttonStyle(.plain)
      .help(isMaximized ? "Minimize" : "Maximize")

      // Close button (inline, hidden when maximized)
      if !isMaximized {
        Button(action: onStopMonitoring) {
          Image(systemName: "xmark")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Stop monitoring")
      }
    }
  }

  // MARK: - Actions Popover Content

  private var actionsPopoverContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Session actions (always visible)
      PopoverButton(icon: "doc.on.doc", title: "Copy Session ID") {
        onCopySessionId()
        showingActionsPopover = false
      }
      PopoverButton(icon: "doc.text", title: "View Transcript") {
        onOpenSessionFile()
        showingActionsPopover = false
      }
      PopoverButton(icon: "rectangle.portrait.and.arrow.right", title: "Open in Terminal") {
        onConnect()
        showingActionsPopover = false
      }
      PopoverButton(icon: "pencil", title: "Name Session") {
        showingActionsPopover = false
        showingNameSheet = true
      }

      // Media actions (only in terminal mode)
      if showTerminal {
        Divider()
          .padding(.vertical, 4)

        PopoverButton(icon: "plus.rectangle.on.folder", title: "Add Files") {
          showingActionsPopover = false
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            showingFilePicker = true
          }
        }
      }
    }
    .padding(8)
  }

  // MARK: - Path Row

  private var pathRow: some View {
    HStack(spacing: 8) {
      // Folder icon and path
      HStack(spacing: 4) {
        Image(systemName: "folder")
          .font(.caption)
          .foregroundColor(.secondary)

        Text(session.projectPath)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      // Branch name in brand color
      if let branch = session.branchName {
        Text(branch)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.brandPrimary)
      }

      Spacer()

      // Pending changes preview button - show immediately when code change tool is detected
      if let pendingToolUse = state?.pendingToolUse,
         pendingToolUse.isCodeChangeTool {
        Button(action: {
          pendingChangesSheetItem = PendingChangesSheetItem(
            session: session,
            pendingToolUse: pendingToolUse
          )
        }) {
          HStack(spacing: 4) {
            Image(systemName: "eye")
              .font(.caption2)
            Text("Preview")
              .font(.caption2)
          }
          .foregroundColor(.orange)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.orange.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Preview pending \(pendingToolUse.toolName) change")
      }

      // Plan button
      if let planState = planState {
        Button(action: {
          planSheetItem = PlanSheetItem(
            session: session,
            planState: planState
          )
        }) {
          HStack(spacing: 4) {
            Image(systemName: "list.bullet.clipboard")
              .font(.caption2)
            Text("Plan")
              .font(.caption2)
          }
          .foregroundColor(.orange)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.orange.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("View session plan")
      }

      // Diff button
      Button(action: {
        gitDiffSheetItem = GitDiffSheetItem(
          session: session,
          projectPath: session.projectPath
        )
      }) {
        HStack(spacing: 4) {
          Image(systemName: "arrow.left.arrow.right")
            .font(.caption2)
          Text("Diff")
            .font(.caption2)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .buttonStyle(.plain)
      .help("View git unstaged changes")

      // Terminal refresh button (only visible when terminal is shown)
      if showTerminal {
        Button(action: onRefreshTerminal) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .font(.caption2)
            Text("Refresh")
              .font(.caption2)
          }
          .foregroundColor(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Refresh terminal (reload session history)")
      }
    }
  }

  // MARK: - Monitor Content

  @ViewBuilder
  private var monitorContent: some View {
    ZStack(alignment: .bottomTrailing) {
      if showTerminal {
        EmbeddedTerminalView(
          terminalKey: terminalKey ?? session.id,
          sessionId: session.id,
          projectPath: session.projectPath,
          claudeClient: claudeClient,
          initialPrompt: initialPrompt,
          viewModel: viewModel
        )
        .frame(minHeight: 300)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("Recent Activity")
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.secondary)

          VStack(alignment: .leading, spacing: 16) {
            // Show recent activities (older first)
            if let state = state {
              ForEach(state.recentActivities.suffix(2).reversed()) { activity in
                FlatActivityRow(activity: activity)
              }
            }

            // Current status as the most recent item
            StatusActivityRow(
              status: state?.status ?? .idle,
              timestamp: state?.lastActivityAt ?? Date()
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }

      // Plus button for actions popover - visible in both modes
      Button {
        showingActionsPopover = true
      } label: {
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 28))
          .foregroundColor(.primary)
          .shadow(color: .primary.opacity(0.4), radius: 4)
      }
      .buttonStyle(.plain)
      .padding(12)
      .popover(isPresented: $showingActionsPopover) {
        actionsPopoverContent
      }
      .help("Session actions")
    }
  }
}

// MARK: - Flat Activity Row

private struct FlatActivityRow: View {
  let activity: ActivityEntry

  private var iconColor: Color {
    switch activity.type {
    case .toolUse:
      return .orange
    case .toolResult(_, let success):
      return success ? .green : .red
    case .userMessage:
      return .blue
    case .assistantMessage:
      return .purple
    case .thinking:
      return .gray
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      Text(formatTime(activity.timestamp))
        .font(.system(.subheadline, design: .monospaced))
        .foregroundColor(.secondary)
        .monospacedDigit()

      Image(systemName: activity.type.icon)
        .font(.subheadline)
        .foregroundColor(iconColor)
        .frame(width: 18)

      Text(activity.description)
        .font(.subheadline)
        .lineLimit(1)
        .foregroundColor(.primary)
    }
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - Status Activity Row

/// Shows the current session status as an activity row
private struct StatusActivityRow: View {
  let status: SessionStatus
  let timestamp: Date

  private var statusColor: Color {
    switch status.color {
    case "blue": return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "red": return .red
    default: return .gray
    }
  }

  private var statusIcon: String {
    switch status {
    case .idle:
      return "circle.fill"
    case .thinking:
      return "sparkles"
    case .executingTool:
      return "gearshape.fill"
    case .awaitingApproval:
      return "exclamationmark.circle.fill"
    case .waitingForUser:
      return "circle.fill"
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      Text(formatTime(timestamp))
        .font(.system(.subheadline, design: .monospaced))
        .foregroundColor(.secondary)
        .monospacedDigit()

      Image(systemName: statusIcon)
        .font(.subheadline)
        .foregroundColor(statusColor)
        .frame(width: 18)

      Text(status.displayName)
        .font(.subheadline)
        .foregroundColor(.primary)
    }
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - PopoverButton

/// A styled button for use in action popovers
private struct PopoverButton: View {
  let icon: String
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .frame(width: 20)
        Text(title)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Animated Copy Button

/// Reusable copy button with animated checkmark confirmation
struct AnimatedCopyButton: View {
  let action: () -> Void
  var size: CGFloat = 24
  var iconFont: Font = .caption
  var showBackground: Bool = true

  @State private var showConfirmation = false

  var body: some View {
    Button {
      action()
      withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
        showConfirmation = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        withAnimation(.easeOut(duration: 0.2)) {
          showConfirmation = false
        }
      }
    } label: {
      Image(systemName: showConfirmation ? "checkmark" : "doc.on.doc")
        .font(iconFont)
        .fontWeight(showConfirmation ? .bold : .regular)
        .foregroundColor(showConfirmation ? .green : .secondary)
        .frame(width: size, height: size)
        .background(showBackground ? Color.secondary.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
    .help("Copy session ID")
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    // Active session with slug
    MonitoringCardView(
      session: CLISession(
        id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
        projectPath: "/Users/james/git/ClaudeCodeUI",
        branchName: "main",
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 42,
        isActive: true,
        slug: "cryptic-orbiting-flame"
      ),
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date(), type: .toolUse(name: "Bash"), description: "swift build")
        ]
      ),
      onToggleTerminal: { _ in },
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )

    // Awaiting approval with slug
    MonitoringCardView(
      session: CLISession(
        id: "f2c9bbf3-3b44-5513-b9f6-997d5e5eb481",
        projectPath: "/Users/james/git/MyProject",
        branchName: "feature/auth",
        isWorktree: true,
        lastActivityAt: Date(),
        messageCount: 15,
        isActive: true,
        slug: "async-coalescing-summit"
      ),
      state: SessionMonitorState(
        status: .awaitingApproval(tool: "git"),
        lastActivityAt: Date(),
        model: "claude-sonnet-4-20250514",
        recentActivities: []
      ),
      onToggleTerminal: { _ in },
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )

    // Loading state (no slug - shows only session ID)
    MonitoringCardView(
      session: CLISession(
        id: "a3d0ccg4-4c55-6624-c0g7-aa8e6f6fc592",
        projectPath: "/Users/james/Desktop",
        branchName: nil,
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 5,
        isActive: false
      ),
      state: nil,
      onToggleTerminal: { _ in },
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )
  }
  .padding()
  .frame(width: 320)
}
