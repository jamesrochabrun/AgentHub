//
//  MonitoringCardView.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

import AgentHubGitHub
import SwiftUI
import UniformTypeIdentifiers

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

/// Identifiable wrapper for web preview sheet
private struct WebPreviewSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
  var agentLocalhostURL: URL?
  var monitorState: SessionMonitorState?
}

/// Identifiable wrapper for GitHub panel sheet
private struct GitHubSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
}

// MARK: - MonitoringCardView

/// Card view for displaying a monitored session in the monitoring panel
public struct MonitoringCardView: View {
  let session: CLISession
  let state: SessionMonitorState?
  let planState: PlanState?
  let cliConfiguration: CLICommandConfiguration?
  let providerKind: SessionProviderKind
  let initialPrompt: String?
  let initialInputText: String?
  let terminalKey: String?  // Key for terminal storage (session ID or "pending-{pendingId}")
  let viewModel: CLISessionsViewModel?
  let editorProjectPath: String
  let editorNavigationRequest: FileExplorerNavigationRequest?
  var dangerouslySkipPermissions: Bool = false
  var permissionModePlan: Bool = false
  let worktreeName: String?
  let onStopMonitoring: () -> Void
  let onConnect: () -> Void
  let onCopySessionId: () -> Void
  let onOpenSessionFile: () -> Void
  let onRefreshTerminal: () -> Void
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?
  let onShowDiff: ((CLISession, String) -> Void)?
  let onShowPlan: ((CLISession, PlanState) -> Void)?
  let onShowWebPreview: ((CLISession, String) -> Void)?
  let onShowMermaid: ((CLISession) -> Void)?
  let onShowGitHub: ((CLISession, String) -> Void)?
  let onPromptConsumed: (() -> Void)?
  let onTerminalInteraction: (() -> Void)?
  let isMaximized: Bool
  let onToggleMaximize: () -> Void
  let isPrimarySession: Bool
  let showPrimaryIndicator: Bool
  var isSidePanelOpen: Bool = false
  @Binding private var contentMode: MonitoringCardContentMode
  @Binding private var selectedEditorFilePath: String?

  @State private var gitDiffSheetItem: GitDiffSheetItem?
  @State private var planSheetItem: PlanSheetItem?
  @State private var pendingChangesSheetItem: PendingChangesSheetItem?
  @State private var webPreviewSheetItem: WebPreviewSheetItem?
  @State private var mermaidSheetSession: CLISession?
  @State private var simulatorSheetSession: CLISession?
  @State private var gitHubSheetItem: GitHubSheetItem?
  @State private var sessionGitHubQuickAccessViewModel = SessionGitHubQuickAccessViewModel()
  @State private var isDragging = false
  @State private var showingActionsPopover = false
  @State private var showingFilePicker = false
  @State private var showingNameSheet = false
  @State private var showingRemixProviderPicker = false
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme

  public init(
    session: CLISession,
    state: SessionMonitorState?,
    planState: PlanState? = nil,
    cliConfiguration: CLICommandConfiguration? = nil,
    providerKind: SessionProviderKind = .claude,
    initialPrompt: String? = nil,
    initialInputText: String? = nil,
    terminalKey: String? = nil,
    viewModel: CLISessionsViewModel? = nil,
    contentMode: Binding<MonitoringCardContentMode> = .constant(.terminal),
    selectedEditorFilePath: Binding<String?> = .constant(nil),
    editorProjectPath: String? = nil,
    editorNavigationRequest: FileExplorerNavigationRequest? = nil,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    worktreeName: String? = nil,
    onStopMonitoring: @escaping () -> Void,
    onConnect: @escaping () -> Void,
    onCopySessionId: @escaping () -> Void,
    onOpenSessionFile: @escaping () -> Void,
    onRefreshTerminal: @escaping () -> Void,
    onInlineRequestSubmit: ((String, CLISession) -> Void)? = nil,
    onShowDiff: ((CLISession, String) -> Void)? = nil,
    onShowPlan: ((CLISession, PlanState) -> Void)? = nil,
    onShowWebPreview: ((CLISession, String) -> Void)? = nil,
    onShowMermaid: ((CLISession) -> Void)? = nil,
    onShowGitHub: ((CLISession, String) -> Void)? = nil,
    onPromptConsumed: (() -> Void)? = nil,
    onTerminalInteraction: (() -> Void)? = nil,
    isMaximized: Bool = false,
    onToggleMaximize: @escaping () -> Void = {},
    isPrimarySession: Bool = false,
    showPrimaryIndicator: Bool = false,
    isSidePanelOpen: Bool = false
  ) {
    self.session = session
    self.state = state
    self.planState = planState
    self.cliConfiguration = cliConfiguration
    self.providerKind = providerKind
    self.initialPrompt = initialPrompt
    self.initialInputText = initialInputText
    self.terminalKey = terminalKey
    self.viewModel = viewModel
    self._contentMode = contentMode
    self._selectedEditorFilePath = selectedEditorFilePath
    self.editorProjectPath = editorProjectPath ?? session.projectPath
    self.editorNavigationRequest = editorNavigationRequest
    self.dangerouslySkipPermissions = dangerouslySkipPermissions
    self.permissionModePlan = permissionModePlan
    self.worktreeName = worktreeName
    self.onStopMonitoring = onStopMonitoring
    self.onConnect = onConnect
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.onRefreshTerminal = onRefreshTerminal
    self.onInlineRequestSubmit = onInlineRequestSubmit
    self.onShowDiff = onShowDiff
    self.onShowPlan = onShowPlan
    self.onShowWebPreview = onShowWebPreview
    self.onShowMermaid = onShowMermaid
    self.onShowGitHub = onShowGitHub
    self.onPromptConsumed = onPromptConsumed
    self.onTerminalInteraction = onTerminalInteraction
    self.isMaximized = isMaximized
    self.onToggleMaximize = onToggleMaximize
    self.isPrimarySession = isPrimarySession
    self.showPrimaryIndicator = showPrimaryIndicator
    self.isSidePanelOpen = isSidePanelOpen
  }

  static func listHeightMetrics(
    providerKind: SessionProviderKind,
    state: SessionMonitorState?
  ) -> ResizableCardMetrics {
    return ResizableCardMetrics(defaultHeight: 520, minHeight: 400)
  }

  private var queuedPreviewContextCount: Int {
    viewModel?.queuedWebPreviewContextStore.count(for: session.id) ?? 0
  }

  private var webPreviewCandidateStatus: WebPreviewCandidateStatus? {
    viewModel?.webPreviewCandidateStatus(for: session.projectPath)
  }

  private var shouldShowWebPreviewButton: Bool {
    WebPreviewCandidateVisibility.shouldShow(
      candidateStatus: webPreviewCandidateStatus,
      detectedLocalhostURL: state?.detectedLocalhostURL
    )
  }

  private var resourceLinks: [ResourceLink] {
    state?.detectedResourceLinks ?? []
  }

  private var shouldShowResourcesPanel: Bool {
    !resourceLinks.isEmpty || sessionGitHubQuickAccessViewModel.currentBranchPR != nil
  }

  private var gitHubQuickAccessCoordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)? {
    viewModel?.agentHubProvider?.gitHubQuickAccessCoordinator ?? agentHub?.gitHubQuickAccessCoordinator
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with session info and actions
      header
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: AgentHubLayout.topBarHeight)

      Divider()

      // Path row with repo path, branch, and GitHub button
      pathRow
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: AgentHubLayout.subBarHeight)

      // Terminal content
      Divider()

      monitorContent

      ResourceLinksPanel(
        links: resourceLinks,
        providerKind: providerKind,
        currentPullRequest: sessionGitHubQuickAccessViewModel.currentBranchPR
      ) {
        Button {
          showingActionsPopover = true
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(Color.brandPrimary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingActionsPopover) {
          actionsPopoverContent
        }
        .help("Session actions")
      }
    }
    .background(.clear)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(
          showPrimaryIndicator && isPrimarySession
           ? Color.brandPrimary(for: providerKind)
            : Color.clear,
          lineWidth: 1
        )
    )
    .shadow(
      color: Color.blue.opacity(isDragging ? 0.875 : 0),
      radius: isDragging ? 12 : 0
    )
    .animation(.easeInOut(duration: 0.2), value: isDragging)
    .task(id: session.projectPath) {
      await loadWebPreviewCandidateIfNeeded()
    }
    .task(id: SessionGitHubQuickAccessViewModel.repositoryKey(projectPath: session.projectPath, branchName: session.branchName)) {
      await sessionGitHubQuickAccessViewModel.load(
        projectPath: session.projectPath,
        branchName: session.branchName,
        coordinator: gitHubQuickAccessCoordinator
      )
      if let lastActivityAt = state?.lastActivityAt {
        await sessionGitHubQuickAccessViewModel.notifySessionActivity(at: lastActivityAt)
      }
    }
    .onDisappear {
      sessionGitHubQuickAccessViewModel.stopPolling()
    }
    .onChange(of: state?.lastActivityAt) { _, newValue in
      guard let newValue else { return }
      Task {
        await sessionGitHubQuickAccessViewModel.notifySessionActivity(at: newValue)
        await loadWebPreviewCandidateIfNeeded()
      }
    }
    .onChange(of: state?.detectedLocalhostURL) { _, newValue in
      guard newValue == nil else { return }
      Task {
        await loadWebPreviewCandidateIfNeeded()
      }
    }
    .onDrop(
      of: [.fileURL, .png, .tiff, .image, .pdf],
      isTargeted: $isDragging
    ) { providers in
      handleDroppedFiles(providers)
      return true
    }
    .modalPanel(
      item: $gitDiffSheetItem,
      title: "Git Diff",
      autosaveName: "com.agenthub.panel.gitDiff"
    ) { item in
      GitDiffView(
        session: item.session,
        projectPath: item.projectPath,
        onDismiss: { gitDiffSheetItem = nil },
        cliConfiguration: cliConfiguration,
        providerKind: providerKind,
        onInlineRequestSubmit: onInlineRequestSubmit
      )
    }
    .sheet(item: $planSheetItem) { item in
      PlanView(
        session: item.session,
        planState: item.planState,
        onDismiss: { planSheetItem = nil },
        providerKind: providerKind,
        onSendFeedback: { feedback, sess in
          viewModel?.showTerminalWithPrompt(for: sess, prompt: feedback)
        }
      )
    }
    .sheet(item: $pendingChangesSheetItem) { item in
      PendingChangesView(
        session: item.session,
        pendingToolUse: item.pendingToolUse,
        onDismiss: { pendingChangesSheetItem = nil },
        onApprovalResponse: { response, session in
          viewModel?.showTerminalWithPrompt(for: session, prompt: response)
        }
      )
    }
    .sheet(item: $webPreviewSheetItem) { item in
      WebPreviewView(
        session: item.session,
        projectPath: item.projectPath,
        onDismiss: { webPreviewSheetItem = nil },
        onInspectSubmit: { prompt, sess in
          if viewModel?.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt) != true {
            viewModel?.showTerminalWithPrompt(for: sess, prompt: prompt)
          }
        },
        onQueuedSubmit: { prompt, sess in
          viewModel?.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt) == true
        },
        viewModel: viewModel,
        agentLocalhostURL: viewModel?.monitorStates[item.session.id]?.detectedLocalhostURL ?? item.agentLocalhostURL,
        monitorState: viewModel?.monitorStates[item.session.id] ?? item.monitorState
      )
    }
    .sheet(item: $mermaidSheetSession) { session in
      MermaidDiagramView(
        session: session,
        onDismiss: { mermaidSheetSession = nil }
      )
    }
    .sheet(item: $simulatorSheetSession) { session in
      SimulatorPickerView(
        session: session,
        onDismiss: { simulatorSheetSession = nil },
        onSendToSession: { error in
          guard let vm = viewModel else { return }
          vm.showTerminalWithPrompt(for: session, prompt: "Fix this build error:\n\(error)")
          simulatorSheetSession = nil
        }
      )
    }
    .modalPanel(
      item: $gitHubSheetItem,
      title: "GitHub",
      autosaveName: "com.agenthub.panel.github"
    ) { item in
      GitHubPanelView(
        projectPath: item.projectPath,
        onDismiss: { gitHubSheetItem = nil },
        isEmbedded: false,
        session: item.session,
        onSendToSession: { prompt, session in
          viewModel?.showTerminalWithPrompt(for: session, prompt: prompt)
          gitHubSheetItem = nil
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
    .sheet(isPresented: $showingRemixProviderPicker) {
      RemixProviderPickerView(session: session, viewModel: viewModel)
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
    guard let key = terminalKey, let viewModel = viewModel else { return }

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
    guard let key = terminalKey, let viewModel = viewModel else { return }

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

  private func presentWebPreview() {
    if let onShowWebPreview {
      onShowWebPreview(session, session.projectPath)
    } else {
      webPreviewSheetItem = WebPreviewSheetItem(
        session: session,
        projectPath: session.projectPath,
        agentLocalhostURL: state?.detectedLocalhostURL,
        monitorState: state
      )
    }
  }

  @MainActor
  private func loadWebPreviewCandidateIfNeeded() async {
    guard state?.detectedLocalhostURL == nil else { return }
    await viewModel?.ensureWebPreviewCandidate(for: session.projectPath)
  }

  private func presentGitHubPanel() {
    if let onShowGitHub {
      onShowGitHub(session, session.projectPath)
    } else {
      gitHubSheetItem = GitHubSheetItem(
        session: session,
        projectPath: session.projectPath
      )
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      // Activity indicator circle - shows when session is working
      Circle()
        .fill(isHighlighted ? Color.brandPrimary(for: providerKind) : .gray.opacity(0.3))
        .frame(width: 10, height: 10)
        .shadow(color: isHighlighted ? Color.brandPrimary(for: providerKind).opacity(0.6) : .clear, radius: 4)

      // Session label - show custom name, slug, or default ID
      if let customName = viewModel?.sessionCustomNames[session.id] {
        Text(customName)
          .font(.primaryDefault)
          .lineLimit(1)
      } else if let slug = session.slug {
        // Show slug (truncates first) and short ID (always shown)
        Text(slug)
          .font(.primaryDefault)
          .lineLimit(1)
        Text("•")
          .font(.secondaryCaption)
          .foregroundColor(.secondary)
          .fixedSize()
          .layoutPriority(1)
        Text(session.shortId)
          .font(.primaryDefault)
          .fixedSize()
          .layoutPriority(1)
      } else {
        Text(session.shortId)
          .font(.primaryDefault)
          .fixedSize()
          .layoutPriority(1)
      }

      // Provider name with brand color
      Text(providerKind.rawValue)
        .font(.secondaryCaption)
        .foregroundColor(.brandPrimary(for: providerKind))
        .fixedSize()
        .layoutPriority(1)

      Spacer()

      // Action buttons — fixed size, never shrink
      HStack(spacing: 6) {
        contentModeToggle

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
              Text("Edits")
            }
          }
          .buttonStyle(.agentHubOutlined(tint: .orange))
          .help("Preview pending \(pendingToolUse.toolName) change")
        }

        // Plan button
        if let planState = planState {
          Button(action: {
            if let onShowPlan = onShowPlan {
              onShowPlan(session, planState)
            } else {
              planSheetItem = PlanSheetItem(
                session: session,
                planState: planState
              )
            }
          }) {
            HStack(spacing: 4) {
              Image(systemName: "list.bullet.clipboard")
                .font(.caption2)
              Text("Plan")
            }
          }
          .buttonStyle(.agentHubOutlined(tint: .orange))
          .help("View session plan")
        }

        // Diff button
        Button(action: {
          if let onShowDiff = onShowDiff {
            onShowDiff(session, session.projectPath)
          } else {
            gitDiffSheetItem = GitDiffSheetItem(
              session: session,
              projectPath: session.projectPath
            )
          }
        }) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.left.arrow.right")
              .font(.caption2)
            Text("Diff")
          }
        }
        .buttonStyle(.agentHubOutlined)
        .help("View git unstaged changes")

        // Web preview button — visible when the project looks like a web project
        // or the agent has already detected a running localhost server
        if shouldShowWebPreviewButton {
          Button(action: presentWebPreview) {
            HStack(spacing: 4) {
              Image(systemName: "globe")
                .font(.caption2)
              Text("Preview")
              if queuedPreviewContextCount > 0 {
                previewContextBadge
              }
            }
          }
          .buttonStyle(.agentHubOutlined)
          .help(queuedPreviewContextCount > 0
            ? "Preview localhost web app (\(queuedPreviewContextCount) queued updates pending next send)"
            : "Preview localhost web app")
        }

        // Mermaid diagram button (only visible when mermaid content is detected)
        if state?.hasMermaidContent == true {
          Button(action: {
            if let onShowMermaid {
              onShowMermaid(session)
            } else {
              mermaidSheetSession = session
            }
          }) {
            HStack(spacing: 4) {
              Image(systemName: "chart.xyaxis.line")
                .font(.caption2)
              Text("Diagram")
            }
          }
          .buttonStyle(.agentHubOutlined)
          .help("View Mermaid diagrams")
        }

        // Simulator button (only visible for Xcode projects)
        if XcodeProjectDetector.isXcodeProject(at: session.projectPath) {
          Button(action: {
            simulatorSheetSession = session
          }) {
            simulatorButtonLabel
          }
          .buttonStyle(.agentHubOutlined)
          .help("Manage iOS Simulators")
        }

        // GitHub button
        Button(action: presentGitHubPanel) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
              .font(.caption2)
            Text("GitHub")
          }
        }
        .buttonStyle(.agentHubOutlined)
        .help("View GitHub PRs, issues, and CI status")

        Button(action: onRefreshTerminal) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .font(.caption2)
            Text("Refresh")
          }
        }
        .buttonStyle(.agentHubOutlined)
        .help("Refresh terminal (reload session history)")
      }
      .fixedSize()
      .layoutPriority(2)

    }
  }

  // MARK: - Simulator Button

  @ViewBuilder
  private var simulatorButtonLabel: some View {
    let service = SimulatorService.shared
    if let udid = service.preferredSimulatorUDIDs[session.projectPath],
       let device = service.device(for: udid) {
      let simState = service.state(for: udid, projectPath: session.projectPath)
      HStack(spacing: 4) {
        Circle()
          .fill(simulatorStatusColor(for: simState, device: device))
          .frame(width: 6, height: 6)
        Text(device.name)
          .lineLimit(1)
      }
    } else {
      HStack(spacing: 4) {
        Image(systemName: "iphone")
          .font(.caption2)
        Text("Simulator")
      }
    }
  }

  private func simulatorStatusColor(for state: SimulatorState, device: SimulatorDevice) -> Color {
    switch state {
    case .idle:
      return device.isBooted ? .green : .gray.opacity(0.5)
    case .booting, .building, .installing, .launching:
      return .yellow
    case .booted:
      return .green
    case .shuttingDown:
      return .orange
    case .failed:
      return .red
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
      if providerKind == .claude {
        PopoverButton(icon: "rectangle.portrait.and.arrow.right", title: "Open in Terminal") {
          onConnect()
          showingActionsPopover = false
        }
      } 
      PopoverButton(icon: "pencil", title: "Name Session") {
        showingActionsPopover = false
        showingNameSheet = true
      }

      // Remix action
      PopoverButton(icon: "arrowshape.zigzag.forward", title: "Remix") {
        showingActionsPopover = false
        showingRemixProviderPicker = true
      }

      Divider()
        .padding(.vertical, DesignTokens.Spacing.xs)

      PopoverButton(icon: "plus.rectangle.on.folder", title: "Add Files") {
        showingActionsPopover = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          showingFilePicker = true
        }
      }
    }
    .padding(DesignTokens.Spacing.sm)
  }

  // MARK: - Path Row

  private var pathRow: some View {
    HStack(spacing: 8) {
      // Folder icon and path
      HStack(spacing: 4) {
        Image(systemName: "folder")
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(session.projectPath)
          .font(.primaryCaption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .layoutPriority(1)

      // Branch name in brand color
      if let branch = session.branchName {
        Text(branch)
          .font(.primaryCaption)
          .foregroundStyle(Color.brandPrimary(for: providerKind))
          .lineLimit(1)
          .layoutPriority(1)
      }

      Spacer(minLength: 8)
    }
    .frame(minHeight: 24)
  }

  // MARK: - Content Mode Toggle

  private var contentModeToggle: some View {
    Picker("", selection: $contentMode) {
      ForEach(MonitoringCardContentMode.allCases) { mode in
        Image(systemName: mode.systemImage)
          .help(mode.label)
          .tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .fixedSize()
    .labelsHidden()
    .help("Switch between terminal and editor")
  }

  // MARK: - Monitor Content

  @ViewBuilder
  private var monitorContent: some View {
    switch contentMode {
    case .terminal:
      terminalContent
    case .editor:
      editorContent
    }
  }

  private var terminalContent: some View {
    EmbeddedTerminalView(
      terminalKey: terminalKey ?? session.id,
      sessionId: session.id,
      projectPath: session.projectPath,
      cliConfiguration: viewModel?.cliConfiguration ?? .claudeDefault,
      initialPrompt: initialPrompt,
      initialInputText: initialInputText,
      viewModel: viewModel,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      onUserInteraction: onTerminalInteraction,
      consumeQueuedWebPreviewContextOnSubmit: {
        viewModel?.consumeQueuedWebPreviewContextPrompt(for: session.id)
      }
    )
    .padding(DesignTokens.Spacing.sm)
    .frame(minHeight: 300)
  }

  private var editorContent: some View {
    FileExplorerView(
      session: session,
      projectPath: editorProjectPath,
      onDismiss: { contentMode = .terminal },
      isEmbedded: false,
      selectedFilePath: $selectedEditorFilePath,
      navigationRequest: editorNavigationRequest
    )
    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    .id("editor-\(session.id)")
  }

  private var previewContextBadge: some View {
    Text("\(queuedPreviewContextCount)")
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(
        Capsule()
          .fill(Color.secondary.opacity(0.15))
      )
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
      .padding(.horizontal, DesignTokens.Spacing.sm)
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
