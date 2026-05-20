//
//  MultiProviderMonitoringPanelView.swift
//  AgentHub
//
//  Combines Claude + Codex monitored sessions into a single panel.
//

import AgentHubGitDiff
import AgentHubGitHub
import Foundation
import PierreDiffsSwift
import SwiftUI

// MARK: - SidePanelContent

private enum SidePanelContent: Equatable {
  case diff(sessionId: String, session: CLISession, projectPath: String)
  case plan(sessionId: String, session: CLISession, planState: PlanState)
  case webPreview(sessionId: String, session: CLISession, projectPath: String, mode: WebPreviewMode)
  case mermaid(sessionId: String, session: CLISession)
  case gitHub(sessionId: String, session: CLISession, projectPath: String)
  case edits(sessionId: String, session: CLISession)

  static func == (lhs: SidePanelContent, rhs: SidePanelContent) -> Bool {
    switch (lhs, rhs) {
    case (.diff(let id1, _, let p1), .diff(let id2, _, let p2)):
      return id1 == id2 && p1 == p2
    case (.plan(let id1, _, _), .plan(let id2, _, _)):
      return id1 == id2
    case (.webPreview(let id1, _, let p1, let m1), .webPreview(let id2, _, let p2, let m2)):
      return id1 == id2 && p1 == p2 && m1 == m2
    case (.mermaid(let id1, _), .mermaid(let id2, _)):
      return id1 == id2
    case (.gitHub(let id1, _, let p1), .gitHub(let id2, _, let p2)):
      return id1 == id2 && p1 == p2
    case (.edits(let id1, _), .edits(let id2, _)):
      return id1 == id2
    default: return false
    }
  }
}

private struct SidePanelPayload: Equatable {
  let itemID: String
  let providerKind: SessionProviderKind
  let content: SidePanelContent
}

// MARK: - GitHubPopOutItem

private struct GitHubPopOutItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
  let viewModel: GitHubViewModel
  let onSendToSession: ((String, CLISession) -> Void)?
}


// MARK: - SessionFileSheetItem

private struct SessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

// MARK: - HubLayoutMode

public enum HubLayoutMode: Int, CaseIterable {
  case single = 0
  case list = 1
  case twoColumn = 2

  public var columnCount: Int {
    switch self {
    case .single: return 1
    case .list: return 1
    case .twoColumn: return 2
    }
  }

  public var icon: String {
    switch self {
    case .single: return "rectangle"
    case .list: return "list.bullet"
    case .twoColumn: return "square.grid.2x2"
    }
  }
}

private typealias LayoutMode = HubLayoutMode

// MARK: - ModuleSectionHeader

private struct ModuleSectionHeader: View {
  let name: String
  let sessionCount: Int

  var body: some View {
    HStack {
      Text(name)
        .font(.secondarySmall)
        .foregroundColor(.secondary)
      Spacer()
      Text("\(sessionCount)")
        .font(.secondarySmall)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 4)
    .padding(.top, 6)
    .padding(.bottom, 10)
  }
}

// MARK: - ProviderMonitoringItem

enum ProviderMonitoringItem: Identifiable {
  case pending(provider: SessionProviderKind, viewModel: CLISessionsViewModel, pending: PendingHubSession)
  case monitored(provider: SessionProviderKind, viewModel: CLISessionsViewModel, session: CLISession, state: SessionMonitorState?)

  var id: String {
    switch self {
    case .pending(let provider, _, let pending):
      return "pending-\(provider.rawValue.lowercased())-\(pending.id.uuidString)"
    case .monitored(let provider, _, let session, _):
      return "\(provider.rawValue.lowercased())-\(session.id)"
    }
  }

  var sessionId: String {
    switch self {
    case .pending(_, _, let pending):
      return "pending-\(pending.id.uuidString)"
    case .monitored(_, _, let session, _):
      return session.id
    }
  }

  var isPending: Bool {
    if case .pending = self {
      return true
    }
    return false
  }

  var projectPath: String {
    switch self {
    case .pending(_, _, let pending):
      return pending.worktree.path
    case .monitored(_, _, let session, _):
      return session.projectPath
    }
  }

  var timestamp: Date {
    switch self {
    case .pending(_, _, let pending):
      return pending.startedAt
    case .monitored(_, _, let session, _):
      return session.lastActivityAt
    }
  }

  var providerKind: SessionProviderKind {
    switch self {
    case .pending(let provider, _, _): return provider
    case .monitored(let provider, _, _, _): return provider
    }
  }

  var viewModel: CLISessionsViewModel {
    switch self {
    case .pending(_, let viewModel, _): return viewModel
    case .monitored(_, let viewModel, _, _): return viewModel
    }
  }
}

private struct HubAuxiliaryShellTarget {
  let context: HubAuxiliaryShellContext
  let viewModel: CLISessionsViewModel
  let displayName: String
}

// MARK: - MultiProviderMonitoringPanelView

public struct MultiProviderMonitoringPanelView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel
  @AppStorage(AgentHubDefaults.auxiliaryShellVisible) var isAuxiliaryShellVisible: Bool = false
  let onEmbeddedSidePanelVisibilityChange: (Bool) -> Void
  let onAddFolder: () -> Void
  let onRequestStartSession: (String?) -> Void

  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var maximizedSessionId: String?
  @State private var sidePanelPresentation = EmbeddedSidePanelPresentationState<SidePanelPayload>()
  @State private var autoOpenedSidePanelKeys: Set<MonitoringAutoOpenSidePanelKey> = []
  @State private var editorStates: [String: MonitoringEditorState] = [:]
  @State private var availableDetailWidth: CGFloat = 0
  @Binding var primarySessionId: String?
  @Binding var selectedModuleLandingPath: String?
  @AppStorage(AgentHubDefaults.hubLayoutMode)
  private var layoutModeRawValue: Int = LayoutMode.single.rawValue
  @AppStorage(AgentHubDefaults.hubPreviousLayoutMode)
  private var previousLayoutModeRawValue: Int = -1
  @AppStorage(AgentHubDefaults.flatSessionLayout)
  private var flatSessionLayout: Bool = false
  @AppStorage(AgentHubDefaults.worktreeDisplayMode)
  private var worktreeDisplayModeRawValue: String = WorktreeDisplayMode.parent.rawValue
  @AppStorage(AgentHubDefaults.diffDisplayMode)
  private var diffDisplayModeRawValue: String = DiffDisplayMode.inline.rawValue
  @State private var showQuickFilePicker = false
  @State private var gitHubPopOutItem: GitHubPopOutItem?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var cardHeights: [String: CGFloat] = [:]
  private let embeddedPrimaryContentMinWidth: CGFloat = 470
  private let embeddedSidePanelMinWidth: CGFloat = 400
  private let embeddedSidePanelDefaultWidth: CGFloat = 700
  private let embeddedSidePanelMaxWidth: CGFloat = 1200
  private let embeddedSidePanelHandleWidth: CGFloat = 8
  private let auxiliaryShellDefaultHeight: CGFloat = 220
  private let auxiliaryShellMinHeight: CGFloat = 140
  private let auxiliaryShellMinMainContentHeight: CGFloat = 260

  private var layoutMode: LayoutMode {
    get { LayoutMode(rawValue: layoutModeRawValue) ?? .single }
  }

  private var allowedEmbeddedSidePanelWidth: CGFloat {
    let availablePanelWidth = availableDetailWidth - embeddedPrimaryContentMinWidth - embeddedSidePanelHandleWidth
    return min(
      embeddedSidePanelMaxWidth,
      max(embeddedSidePanelMinWidth, availablePanelWidth)
    )
  }

  private func wantsEmbeddedSidePanelPresentation(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> Bool {
    layoutMode == .single
      && maximizedSessionId == nil
      && activeModuleLandingPath(snapshot: snapshot) == nil
      && sidePanelPresentation.shellPayload != nil
      && !snapshot.visibleItems.isEmpty
  }

  private var wantsEmbeddedSidePanelPresentation: Bool {
    wantsEmbeddedSidePanelPresentation(snapshot: makeItemSnapshot())
  }

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    primarySessionId: Binding<String?>,
    selectedModuleLandingPath: Binding<String?> = .constant(nil),
    onEmbeddedSidePanelVisibilityChange: @escaping (Bool) -> Void = { _ in },
    onAddFolder: @escaping () -> Void,
    onRequestStartSession: @escaping (String?) -> Void
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self._primarySessionId = primarySessionId
    self._selectedModuleLandingPath = selectedModuleLandingPath
    self.onEmbeddedSidePanelVisibilityChange = onEmbeddedSidePanelVisibilityChange
    self.onAddFolder = onAddFolder
    self.onRequestStartSession = onRequestStartSession
  }

  public var body: some View {
    let snapshot = makeItemSnapshot()
    let wantsSidePanelPresentation = wantsEmbeddedSidePanelPresentation(snapshot: snapshot)
    let auxiliaryTarget = auxiliaryShellTarget(snapshot: snapshot)
    let autoOpenCandidate = autoOpenSidePanelCandidate(snapshot: snapshot)

    GeometryReader { geometry in
      VStack(spacing: 0) {
        mainContent(snapshot: snapshot)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if isAuxiliaryShellVisible, let target = auxiliaryTarget {
          auxiliaryShellDock(
            for: target,
            availableHeight: geometry.size.height
          )
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
          .transition(auxiliaryShellDockTransition)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
    }
    .background(monitorContainerBackgroundColor)
    .cornerRadius(8)
    .onAppear {
      onEmbeddedSidePanelVisibilityChange(wantsSidePanelPresentation)
      syncEditorStates(snapshot: snapshot)
      syncAuxiliaryShellDockState(target: auxiliaryTarget)
      openAutoSidePanelIfNeeded(candidate: autoOpenCandidate)
    }
    .onChange(of: wantsSidePanelPresentation) { _, wantsPresentation in
      onEmbeddedSidePanelVisibilityChange(wantsPresentation)
    }
    .onChange(of: snapshot.itemIDs) { _, _ in
      syncEditorStates()
      pruneAutoOpenedSidePanelKeys()
    }
    .onChange(of: snapshot.effectivePrimaryItemID) { _, _ in
      syncAuxiliaryShellDockState()
    }
    .onChange(of: activeModuleLandingPath(snapshot: snapshot)) { _, activePath in
      guard activePath != nil else { return }
      maximizedSessionId = nil
      closeEmbeddedSidePanel()
    }
    .onChange(of: isAuxiliaryShellVisible) { _, _ in
      syncAuxiliaryShellDockState()
    }
    .onChange(of: claudeViewModel.pendingFileOpen?.filePath) { _, _ in
      consumePendingFileOpen(from: claudeViewModel, providerKind: .claude)
    }
    .onChange(of: codexViewModel.pendingFileOpen?.filePath) { _, _ in
      consumePendingFileOpen(from: codexViewModel, providerKind: .codex)
    }
    .onChange(of: autoOpenCandidate?.key) { _, _ in
      openAutoSidePanelIfNeeded()
    }
    .overlay {
      Group {
        Button("") { showQuickFilePicker = true }
          .keyboardShortcut("p", modifiers: [.command])

        Button("") { togglePrimarySessionContentMode() }
          .keyboardShortcut("`", modifiers: [.option])

        Button("") { togglePrimarySessionContentMode() }
          .keyboardShortcut("`", modifiers: [.control])
      }
      .frame(width: 0, height: 0)
      .hidden()
    }
    .onReceive(NotificationCenter.default.publisher(for: .toggleMonitoringContentMode)) { _ in
      togglePrimarySessionContentMode()
    }
    .floatingPanel(isPresented: $showQuickFilePicker, defaultSize: CGSize(width: 680, height: 640)) {
      if let primaryItem = snapshot.effectivePrimaryItem {
        QuickFilePickerView(
          isPresented: $showQuickFilePicker,
          projectPath: editorState(for: primaryItem).projectPath,
          onFileSelected: { path in
            showQuickFilePicker = false
            openFileInEditor(
              for: primaryItem.id,
              filePath: path,
              projectPath: editorState(for: primaryItem).projectPath,
              lineNumber: nil,
              makePrimary: false
            )
          }
        )
      }
    }
    .modalPanel(
      item: $gitHubPopOutItem,
      title: "GitHub",
      autosaveName: "com.agenthub.panel.github"
    ) { item in
      GitHubPanelView(
        projectPath: item.projectPath,
        branchName: item.session.branchName,
        onDismiss: { gitHubPopOutItem = nil },
        isEmbedded: false,
        session: item.session,
        viewModel: item.viewModel,
        onSendToSession: item.onSendToSession
      )
      .onDisappear {
        item.viewModel.stopObserving()
      }
    }
    .sheet(item: $sessionFileSheetItem) { item in
      MonitoringSessionFileSheetView(
        session: item.session,
        fileName: item.fileName,
        content: item.content,
        onDismiss: { sessionFileSheetItem = nil }
      )
    }
    .onKeyPress(.escape) {
      if maximizedSessionId != nil {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
          maximizedSessionId = nil
        }
        return .handled
      }
      return .ignored
    }
    .onAppear {
      ensurePrimarySelection(snapshot: snapshot)
    }
    .onChange(of: snapshot.itemIDs) { _, _ in
      ensurePrimarySelection()
    }
    .onChange(of: snapshot.effectivePrimaryItemID) { _, newId in
      guard let currentSidePanelPayload = sidePanelPresentation.currentPayload else { return }
      let currentSnapshot = makeItemSnapshot()
      if case .webPreview(let sessionId, _, let projectPath, let mode) = currentSidePanelPayload.content,
         sessionId.hasPrefix("pending-"),
         let newId,
         let item = currentSnapshot.allItems.first(where: { $0.id == newId }),
         case .monitored(_, _, let session, _) = item,
         session.projectPath == projectPath {
        openEmbeddedSidePanel(
          SidePanelPayload(
            itemID: item.id,
            providerKind: item.providerKind,
            content: .webPreview(
              sessionId: session.id,
              session: session,
              projectPath: session.projectPath,
              mode: mode
            )
          )
        )
      } else {
        if let newId {
          if currentSidePanelPayload.itemID != newId {
            closeEmbeddedSidePanel()
          }
        } else {
          closeEmbeddedSidePanel()
        }
      }
    }
    .onChange(of: primarySessionId) { _, newId in
      guard let newId else { return }
      if let item = makeItemSnapshot().allItems.first(where: { $0.id == newId }) {
        item.viewModel.focusTerminal(forKey: item.sessionId)
      }
    }
  }

  private var monitorContainerBackgroundColor: Color {
    let defaultBackground = colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.96)
    if runtimeTheme?.hasCustomBackgrounds == true {
      return Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    }
    return defaultBackground
  }

  private var maximizedContainerBackgroundColor: Color {
    let defaultBackground = colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.92)
    if runtimeTheme?.hasCustomBackgrounds == true {
      return Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    }
    return defaultBackground
  }

  private var embeddedSidePanelContentAnimation: Animation {
    accessibilityReduceMotion ? .easeOut(duration: 0.08) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
  }

  private var embeddedSidePanelCloseShellDelay: Duration {
    accessibilityReduceMotion ? .milliseconds(50) : .milliseconds(120)
  }

  private var embeddedSidePanelContentTransition: AnyTransition {
    if accessibilityReduceMotion {
      return .opacity
    }
    return .asymmetric(
      insertion: .move(edge: .trailing).combined(with: .opacity),
      removal: .move(edge: .trailing).combined(with: .opacity)
    )
  }

  private var auxiliaryShellToggleAnimation: Animation {
    accessibilityReduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.9)
  }

  private var auxiliaryShellDockTransition: AnyTransition {
    accessibilityReduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
  }

  @ViewBuilder
  private func mainContent(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> some View {
    if let maximizedId = maximizedSessionId {
      maximizedCardContent(for: maximizedId, snapshot: snapshot)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(maximizedContainerBackgroundColor)
    } else {
      mainContentBody(snapshot: snapshot)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }

  @ViewBuilder
  private func mainContentBody(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> some View {
    if let modulePath = activeModuleLandingPath(snapshot: snapshot) {
      ModuleLandingView(
        modulePath: modulePath,
        onStartSession: { onRequestStartSession(modulePath) }
      )
    } else if !snapshot.allItems.isEmpty {
      monitoredSessionsList(snapshot: snapshot)
    } else if isLoading {
      loadingState
    } else {
      emptyState
    }
  }

  // MARK: - Loading State

  private var isLoading: Bool {
    claudeViewModel.isLoading || codexViewModel.isLoading
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .scaleEffect(0.8)
      Text(loadingMessage)
        .font(.primaryDefault)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var loadingMessage: String {
    if claudeViewModel.isLoading {
      return claudeViewModel.loadingState.message
    }
    if codexViewModel.isLoading {
      return codexViewModel.loadingState.message
    }
    return "Loading sessions..."
  }

  // MARK: - Empty State

  private var emptyState: some View {
    WelcomeView(
      viewModel: emptyStateViewModel,
      onAddFolder: onAddFolder,
      onStartSession: onRequestStartSession
    )
  }

  // MARK: - Monitored Sessions List

  @ViewBuilder
  private func monitoredSessionsList(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> some View {
    if layoutMode == .single {
      singleModeContent(snapshot: snapshot)
        .background(
          GeometryReader { geometry in
            Color.clear
              .onAppear { availableDetailWidth = geometry.size.width }
              .onChange(of: geometry.size.width) { _, newWidth in
                availableDetailWidth = newWidth
              }
          }
        )
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          if layoutMode == .list {
            listModeContent(snapshot: snapshot)
          } else {
            let columns = Array(repeating: GridItem(.flexible(), alignment: .top), count: layoutMode.columnCount)
            if flatSessionLayout {
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(snapshot.flatSortedItems) { item in
                  itemCardView(for: item, effectivePrimaryItemID: snapshot.effectivePrimaryItemID)
                }
              }
              .padding(12)
              .transition(.opacity)
            } else {
              LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
                monitoredSessionsGroupedContent(snapshot: snapshot)
              }
              .padding(12)
              .transition(.opacity)
            }
          }
        }
        .animation(.easeInOut(duration: 0.2), value: layoutMode)
        .animation(.easeInOut(duration: 0.25), value: flatSessionLayout)
        .onChange(of: primarySessionId) { _, newId in
          guard let newId else { return }
          withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(newId, anchor: .top)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func listModeContent(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> some View {
    VStack(spacing: 12) {
      if flatSessionLayout {
        ForEach(snapshot.flatSortedItems) { item in
          listModeCard(for: item, effectivePrimaryItemID: snapshot.effectivePrimaryItemID)
        }
      } else {
        listModeGroupedContent(snapshot: snapshot)
      }
    }
    .padding(12)
    .transition(.opacity)
  }

  // MARK: - Single Mode Content

  @ViewBuilder
  private func singleModeContent(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> some View {
    if let item = snapshot.visibleItems.first {
      switch item {
      case .pending(_, let viewModel, let pending):
        let pendingId = "pending-\(pending.id.uuidString)"
        singleModeCardContainer(viewModel: viewModel) {
          MonitoringCardView(
            session: pending.placeholderSession,
            state: nil,
            cliConfiguration: viewModel.cliConfiguration,
            providerKind: item.providerKind,
            initialPrompt: pending.initialPrompt,
            initialInputText: pending.initialInputText,
            terminalKey: pendingId,
            viewModel: viewModel,
            contentMode: editorContentModeBinding(for: item),
            selectedEditorFilePath: selectedEditorFilePathBinding(for: item),
            editorProjectPath: editorState(for: item).projectPath,
            editorNavigationRequest: editorState(for: item).navigationRequest,
            dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
            permissionModePlan: pending.permissionModePlan,
            worktreeName: pending.worktreeName,
            onStopMonitoring: { viewModel.cancelPendingSession(pending) },
            onConnect: { },
            onCopySessionId: { },
            onOpenSessionFile: { },
            onRefreshTerminal: { },
            onShowDiff: { session, projectPath in
              toggleSidePanel(
                .diff(sessionId: session.id, session: session, projectPath: projectPath),
                forItemID: item.id
              )
            },
            onShowPlan: { session, planState in
              toggleSidePanel(
                .plan(sessionId: session.id, session: session, planState: planState),
                forItemID: item.id
              )
            },
            onShowWebPreview: { session, projectPath, mode in
              presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath, mode: mode)
            },
            onShowMermaid: { session in
              toggleSidePanel(
                .mermaid(sessionId: session.id, session: session),
                forItemID: item.id
              )
            },
            onShowGitHub: { session, projectPath in
              toggleSidePanel(
                .gitHub(sessionId: session.id, session: session, projectPath: projectPath),
                forItemID: item.id
              )
            },
            onShowPendingChanges: { session, _ in
              toggleSidePanel(
                .edits(sessionId: session.id, session: session),
                forItemID: item.id
              )
            },
            onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
            onRequestShowEditor: { setContentMode(.editor, for: item) },
            isMaximized: false,
            onToggleMaximize: { },
            isPrimarySession: true,
            showPrimaryIndicator: false
          )
          .id(pendingId)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

      case .monitored(_, let viewModel, let session, let state):
        let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
        let initialPrompt = viewModel.pendingPrompt(for: session.id)

        singleModeCardContainer(viewModel: viewModel) {
          MonitoringCardView(
            session: session,
            state: state,
            planState: planState,
            cliConfiguration: viewModel.cliConfiguration,
            providerKind: item.providerKind,
            initialPrompt: initialPrompt,
            terminalKey: session.id,
            viewModel: viewModel,
            contentMode: editorContentModeBinding(for: item),
            selectedEditorFilePath: selectedEditorFilePathBinding(for: item),
            editorProjectPath: editorState(for: item).projectPath,
            editorNavigationRequest: editorState(for: item).navigationRequest,
            onStopMonitoring: {
              viewModel.stopMonitoring(session: session)
            },
            onConnect: {
              _ = viewModel.connectToSession(session)
            },
            onCopySessionId: {
              viewModel.copySessionId(session)
            },
            onOpenSessionFile: {
              openSessionFile(for: session, viewModel: viewModel)
            },
            onRefreshTerminal: {
              viewModel.refreshTerminal(
                forKey: session.id,
                sessionId: session.id,
                projectPath: session.projectPath
              )
            },
            onInlineRequestSubmit: { prompt, sess in
              viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
            },
            onShowDiff: { session, projectPath in
              toggleSidePanel(
                .diff(sessionId: session.id, session: session, projectPath: projectPath),
                forItemID: item.id
              )
            },
            onShowPlan: { session, planState in
              toggleSidePanel(
                .plan(sessionId: session.id, session: session, planState: planState),
                forItemID: item.id
              )
            },
            onShowWebPreview: { session, projectPath, mode in
              presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath, mode: mode)
            },
            onShowMermaid: { session in
              toggleSidePanel(
                .mermaid(sessionId: session.id, session: session),
                forItemID: item.id
              )
            },
            onShowGitHub: { session, projectPath in
              toggleSidePanel(
                .gitHub(sessionId: session.id, session: session, projectPath: projectPath),
                forItemID: item.id
              )
            },
            onShowPendingChanges: { session, _ in
              toggleSidePanel(
                .edits(sessionId: session.id, session: session),
                forItemID: item.id
              )
            },
            onPromptConsumed: {
              viewModel.clearPendingPrompt(for: session.id)
            },
            onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
            onRequestShowEditor: { setContentMode(.editor, for: item) },
            isMaximized: false,
            onToggleMaximize: { },
            isPrimarySession: true,
            showPrimaryIndicator: false
          )
          .id(session.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  @ViewBuilder
  private func singleModeCardContainer<Content: View>(
    viewModel: CLISessionsViewModel,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 0) {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .blursWhileResizing()

      if let shellPayload = sidePanelPresentation.shellPayload {
        ResizablePanelContainer(
          side: .trailing,
          minWidth: embeddedSidePanelMinWidth,
          maxWidth: allowedEmbeddedSidePanelWidth,
          defaultWidth: min(embeddedSidePanelDefaultWidth, allowedEmbeddedSidePanelWidth),
          userDefaultsKey: AgentHubDefaults.sidePanelWidth
        ) {
          ZStack {
            if let mountedPayload = sidePanelPresentation.mountedPayload,
               mountedPayload == shellPayload {
              sidePanelView(for: mountedPayload, viewModel: viewModel)
                .transition(embeddedSidePanelContentTransition)
            } else {
              Color.clear
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
        }
        .animation(embeddedSidePanelContentAnimation, value: sidePanelPresentation.mountedPayload)
      }
    }
  }

  private func presentWebPreviewInSidePanel(forItemID itemID: String, session: CLISession, projectPath: String, mode: WebPreviewMode) {
    toggleSidePanel(
      .webPreview(sessionId: session.id, session: session, projectPath: projectPath, mode: mode),
      forItemID: itemID
    )
  }

  private func autoOpenSidePanelCandidate(
    snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>
  ) -> MonitoringAutoOpenSidePanelCandidate? {
    MonitoringAutoOpenSidePanelPolicy.candidate(
      layoutMode: layoutMode,
      maximizedSessionId: maximizedSessionId,
      activeModuleLandingPath: activeModuleLandingPath(snapshot: snapshot),
      visibleItem: snapshot.visibleItems.first.flatMap { autoOpenSidePanelItem(for: $0) },
      openedKeys: autoOpenedSidePanelKeys
    )
  }

  private func autoOpenSidePanelItem(
    for item: ProviderMonitoringItem
  ) -> MonitoringAutoOpenSidePanelItem? {
    switch item {
    case .pending:
      return nil
    case .monitored(_, _, let session, let state):
      return MonitoringAutoOpenSidePanelItem(
        itemID: item.id,
        providerKind: item.providerKind,
        session: session,
        state: state
      )
    }
  }

  private func openAutoSidePanelIfNeeded(
    candidate: MonitoringAutoOpenSidePanelCandidate? = nil
  ) {
    guard let candidate = candidate ?? autoOpenSidePanelCandidate(snapshot: makeItemSnapshot()) else {
      return
    }

    autoOpenedSidePanelKeys.insert(candidate.key)

    let payload = SidePanelPayload(
      itemID: candidate.itemID,
      providerKind: candidate.providerKind,
      content: sidePanelContent(for: candidate)
    )
    guard sidePanelPresentation.currentPayload != payload else { return }
    openEmbeddedSidePanel(payload)
  }

  private func sidePanelContent(
    for candidate: MonitoringAutoOpenSidePanelCandidate
  ) -> SidePanelContent {
    switch candidate.target {
    case .edits:
      return .edits(sessionId: candidate.session.id, session: candidate.session)
    case .plan(let planState):
      return .plan(
        sessionId: candidate.session.id,
        session: candidate.session,
        planState: planState
      )
    }
  }

  private func pruneAutoOpenedSidePanelKeys() {
    let activeSessionIDs = Set(allItems.map(\.sessionId))
    autoOpenedSidePanelKeys = Set(autoOpenedSidePanelKeys.filter {
      activeSessionIDs.contains($0.sessionID)
    })
  }

  /// Ensures the single-mode inline layout is active for `itemID`, then toggles the requested
  /// side panel content (open if not already presenting it; close if re-selected).
  private func toggleSidePanel(_ content: SidePanelContent, forItemID itemID: String) {
    let payload = SidePanelPayload(
      itemID: itemID,
      providerKind: providerKind(forItemID: itemID),
      content: content
    )

    performWithoutAnimation {
      if primarySessionId != itemID {
        primarySessionId = itemID
      }
      if layoutMode != .single {
        layoutModeRawValue = LayoutMode.single.rawValue
      }
      if maximizedSessionId != nil {
        maximizedSessionId = nil
      }
    }

    if sidePanelPresentation.currentPayload == payload {
      closeEmbeddedSidePanel()
    } else {
      openEmbeddedSidePanel(payload)
    }
  }

  private func openEmbeddedSidePanel(_ payload: SidePanelPayload) {
    let transitionID = sidePanelPresentation.open(payload)
    completeDeferredSidePanelTransition(transitionID)
  }

  private func closeEmbeddedSidePanel() {
    let transitionID = sidePanelPresentation.close()
    completeDeferredSidePanelTransition(transitionID, delay: embeddedSidePanelCloseShellDelay)
  }

  private func completeDeferredSidePanelTransition(_ transitionID: UInt64, delay: Duration? = nil) {
    Task { @MainActor [sidePanelPresentation] in
      if let delay {
        try? await Task.sleep(for: delay)
      } else {
        await Task.yield()
      }
      sidePanelPresentation.completeDeferredTransition(id: transitionID)
    }
  }

  private func providerKind(forItemID itemID: String) -> SessionProviderKind {
    allItems.first(where: { $0.id == itemID })?.providerKind ?? .claude
  }

  private func performWithoutAnimation(_ updates: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, updates)
  }

  @ViewBuilder
  private func sidePanelView(for payload: SidePanelPayload, viewModel: CLISessionsViewModel) -> some View {
    switch payload.content {
    case .diff(_, let session, let projectPath):
      GitDiffView(
        session: session,
        projectPath: projectPath,
        onDismiss: closeEmbeddedSidePanel,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: payload.providerKind,
        onInlineRequestSubmit: { prompt, sess in
          closeEmbeddedSidePanel()
          showTerminalWithPrompt(
            prompt,
            for: sess,
            itemID: payload.itemID,
            viewModel: viewModel
          )
        },
        isEmbedded: true
      )
    case .plan(_, let session, let planState):
      PlanView(
        session: session,
        planState: planState,
        onDismiss: closeEmbeddedSidePanel,
        isEmbedded: true,
        providerKind: payload.providerKind,
        onSendFeedback: { feedback, sess in
          closeEmbeddedSidePanel()
          showTerminalWithPrompt(
            feedback,
            for: sess,
            itemID: payload.itemID,
            viewModel: viewModel
          )
        }
      )
    case .webPreview(let sessionId, let session, let projectPath, let mode):
      WebPreviewView(
        session: session,
        projectPath: projectPath,
        onDismiss: closeEmbeddedSidePanel,
        isEmbedded: true,
        onInspectSubmit: { prompt, sess in
          if !viewModel.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt) {
            viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
          }
        },
        onQueuedSubmit: { prompt, sess in
          viewModel.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt)
        },
        viewModel: viewModel,
        mode: mode,
        agentLocalhostURL: viewModel.monitorStates[sessionId]?.detectedLocalhostURL,
        monitorState: viewModel.monitorStates[sessionId]
      )
    case .mermaid(_, let session):
      MermaidDiagramView(
        session: session,
        onDismiss: closeEmbeddedSidePanel,
        isEmbedded: true
      )
    case .gitHub(_, let session, let projectPath):
      let gitHubViewModel = GitHubViewModel(
        service: viewModel.agentHubProvider?.gitHubService ?? GitHubCLIService(),
        observationService: viewModel.agentHubProvider?.gitHubPRObservationService
      )
      GitHubPanelView(
        projectPath: projectPath,
        branchName: session.branchName,
        onDismiss: closeEmbeddedSidePanel,
        isEmbedded: true,
        session: session,
        viewModel: gitHubViewModel,
        onSendToSession: { prompt, sess in viewModel.showTerminalWithPrompt(for: sess, prompt: prompt) },
        onPopOut: { panelViewModel in
          closeEmbeddedSidePanel()
          gitHubPopOutItem = GitHubPopOutItem(
            session: session,
            projectPath: projectPath,
            viewModel: panelViewModel,
            onSendToSession: { prompt, sess in viewModel.showTerminalWithPrompt(for: sess, prompt: prompt) }
          )
        }
      )
    case .edits(let sessionId, let session):
      if let pendingToolUse = viewModel.monitorStates[sessionId]?.pendingToolUse {
        PendingChangesView(
          session: session,
          pendingToolUse: pendingToolUse,
          onDismiss: closeEmbeddedSidePanel,
          isEmbedded: true,
          onApprovalResponse: { response, sess in
            viewModel.showTerminalWithPrompt(for: sess, prompt: response)
          }
        )
      } else {
        PendingChangesWaitingView(
          session: session,
          onDismiss: closeEmbeddedSidePanel
        )
      }
    }
  }

  // MARK: - Single Card View

  @ViewBuilder
  private func itemCardView(
    for item: ProviderMonitoringItem,
    effectivePrimaryItemID: String? = nil
  ) -> some View {
    let isPrimary = item.id == (effectivePrimaryItemID ?? effectivePrimarySessionId)
    switch item {
    case .pending(_, let viewModel, let pending):
      MonitoringCardView(
        session: pending.placeholderSession,
        state: nil,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: item.providerKind,
        initialPrompt: pending.initialPrompt,
        initialInputText: pending.initialInputText,
        terminalKey: "pending-\(pending.id.uuidString)",
        viewModel: viewModel,
        contentMode: editorContentModeBinding(for: item),
        selectedEditorFilePath: selectedEditorFilePathBinding(for: item),
        editorProjectPath: editorState(for: item).projectPath,
        editorNavigationRequest: editorState(for: item).navigationRequest,
        dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
        permissionModePlan: pending.permissionModePlan,
        worktreeName: pending.worktreeName,
        shouldMountTerminal: shouldMountTerminal(for: item, isPrimary: isPrimary),
        onStopMonitoring: { viewModel.cancelPendingSession(pending) },
        onConnect: { },
        onCopySessionId: { },
        onOpenSessionFile: { },
        onRefreshTerminal: { },
        onRequestMountTerminal: { setPrimarySessionIfNeeded(item.id) },
        onShowDiff: { session, projectPath in
          toggleSidePanel(
            .diff(sessionId: session.id, session: session, projectPath: projectPath),
            forItemID: item.id
          )
        },
        onShowPlan: { session, planState in
          toggleSidePanel(
            .plan(sessionId: session.id, session: session, planState: planState),
            forItemID: item.id
          )
        },
        onShowWebPreview: { session, projectPath, mode in
          presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath, mode: mode)
        },
        onShowMermaid: { session in
          toggleSidePanel(
            .mermaid(sessionId: session.id, session: session),
            forItemID: item.id
          )
        },
        onShowGitHub: { session, projectPath in
          toggleSidePanel(
            .gitHub(sessionId: session.id, session: session, projectPath: projectPath),
            forItemID: item.id
          )
        },
        onShowPendingChanges: { session, _ in
          toggleSidePanel(
            .edits(sessionId: session.id, session: session),
            forItemID: item.id
          )
        },
        onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
        onRequestShowEditor: { setContentMode(.editor, for: item) },
        isMaximized: maximizedSessionId == item.id,
        onToggleMaximize: {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            maximizedSessionId = maximizedSessionId == item.id ? nil : item.id
          }
        },
        isPrimarySession: isPrimary,
        showPrimaryIndicator: layoutMode != .single
      )
      .id(item.id)

    case .monitored(_, let viewModel, let session, let state):
      let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
      let initialPrompt = viewModel.pendingPrompt(for: session.id)

      MonitoringCardView(
        session: session,
        state: state,
        planState: planState,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: item.providerKind,
        initialPrompt: initialPrompt,
        terminalKey: session.id,
        viewModel: viewModel,
        contentMode: editorContentModeBinding(for: item),
        selectedEditorFilePath: selectedEditorFilePathBinding(for: item),
        editorProjectPath: editorState(for: item).projectPath,
        editorNavigationRequest: editorState(for: item).navigationRequest,
        shouldMountTerminal: shouldMountTerminal(for: item, isPrimary: isPrimary),
        onStopMonitoring: {
          viewModel.stopMonitoring(session: session)
        },
        onConnect: {
          _ = viewModel.connectToSession(session)
        },
        onCopySessionId: {
          viewModel.copySessionId(session)
        },
        onOpenSessionFile: {
          openSessionFile(for: session, viewModel: viewModel)
        },
        onRefreshTerminal: {
          viewModel.refreshTerminal(
            forKey: session.id,
            sessionId: session.id,
            projectPath: session.projectPath
          )
        },
        onRequestMountTerminal: { setPrimarySessionIfNeeded(item.id) },
        onInlineRequestSubmit: { prompt, sess in
          viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
        },
        onShowDiff: { session, projectPath in
          toggleSidePanel(
            .diff(sessionId: session.id, session: session, projectPath: projectPath),
            forItemID: item.id
          )
        },
        onShowPlan: { session, planState in
          toggleSidePanel(
            .plan(sessionId: session.id, session: session, planState: planState),
            forItemID: item.id
          )
        },
        onShowWebPreview: { session, projectPath, mode in
          presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath, mode: mode)
        },
        onShowMermaid: { session in
          toggleSidePanel(
            .mermaid(sessionId: session.id, session: session),
            forItemID: item.id
          )
        },
        onShowGitHub: { session, projectPath in
          toggleSidePanel(
            .gitHub(sessionId: session.id, session: session, projectPath: projectPath),
            forItemID: item.id
          )
        },
        onShowPendingChanges: { session, _ in
          toggleSidePanel(
            .edits(sessionId: session.id, session: session),
            forItemID: item.id
          )
        },
        onPromptConsumed: {
          viewModel.clearPendingPrompt(for: session.id)
        },
        onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
        onRequestShowEditor: { setContentMode(.editor, for: item) },
        isMaximized: maximizedSessionId == item.id,
        onToggleMaximize: {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            maximizedSessionId = maximizedSessionId == item.id ? nil : item.id
          }
        },
        isPrimarySession: isPrimary,
        showPrimaryIndicator: layoutMode != .single
      )
      .id(item.id)
    }
  }

  // MARK: - Grouped Content by Module

  @ViewBuilder
  private func listModeGroupedContent(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(snapshot.groupedItems, id: \.modulePath) { group in
        VStack(alignment: .leading, spacing: 12) {
          ModuleSectionHeader(
            name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
            sessionCount: group.items.count
          )

          ForEach(group.items) { item in
            listModeCard(for: item, effectivePrimaryItemID: snapshot.effectivePrimaryItemID)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func monitoredSessionsGroupedContent(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> some View {
    ForEach(snapshot.groupedItems, id: \.modulePath) { group in
      Section(header: ModuleSectionHeader(
        name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
        sessionCount: group.items.count
      )) {
        ForEach(group.items) { item in
          itemCardView(for: item, effectivePrimaryItemID: snapshot.effectivePrimaryItemID)
        }
      }
    }
  }

  private var effectivePrimarySessionId: String? {
    makeItemSnapshot().effectivePrimaryItemID
  }

  private var visibleItems: [ProviderMonitoringItem] {
    makeItemSnapshot().visibleItems
  }

  private func makeItemSnapshot() -> MonitoringItemsSnapshot<ProviderMonitoringItem> {
    MonitoringItemsSnapshot(
      items: allItems,
      primaryItemID: primarySessionId,
      layoutMode: layoutMode,
      modulePath: { findModulePath(for: $0) },
      timestamp: { $0.timestamp }
    )
  }

  // MARK: - Helpers

  @ViewBuilder
  private func maximizedCardContent(
    for itemId: String,
    snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>
  ) -> some View {
    if let item = snapshot.allItems.first(where: { $0.id == itemId }) {
      let isPrimary = item.id == snapshot.effectivePrimaryItemID
      switch item {
      case .pending(_, let viewModel, let pending):
        MonitoringCardView(
          session: pending.placeholderSession,
          state: nil,
          cliConfiguration: viewModel.cliConfiguration,
          providerKind: item.providerKind,
          initialPrompt: pending.initialPrompt,
          initialInputText: pending.initialInputText,
          terminalKey: "pending-\(pending.id.uuidString)",
          viewModel: viewModel,
          contentMode: editorContentModeBinding(for: item),
          selectedEditorFilePath: selectedEditorFilePathBinding(for: item),
          editorProjectPath: editorState(for: item).projectPath,
          editorNavigationRequest: editorState(for: item).navigationRequest,
          dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
          permissionModePlan: pending.permissionModePlan,
          worktreeName: pending.worktreeName,
          onStopMonitoring: {
            viewModel.cancelPendingSession(pending)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          onConnect: { },
          onCopySessionId: { },
          onOpenSessionFile: { },
          onRefreshTerminal: { },
          onShowDiff: { session, projectPath in
            toggleSidePanel(
              .diff(sessionId: session.id, session: session, projectPath: projectPath),
              forItemID: itemId
            )
          },
          onShowPlan: { session, planState in
            toggleSidePanel(
              .plan(sessionId: session.id, session: session, planState: planState),
              forItemID: itemId
            )
          },
          onShowWebPreview: { session, projectPath, mode in
            presentWebPreviewInSidePanel(forItemID: itemId, session: session, projectPath: projectPath, mode: mode)
          },
          onShowMermaid: { session in
            toggleSidePanel(
              .mermaid(sessionId: session.id, session: session),
              forItemID: itemId
            )
          },
          onShowGitHub: { session, projectPath in
            toggleSidePanel(
              .gitHub(sessionId: session.id, session: session, projectPath: projectPath),
              forItemID: itemId
            )
          },
          onShowPendingChanges: { session, _ in
            toggleSidePanel(
              .edits(sessionId: session.id, session: session),
              forItemID: itemId
            )
          },
          onTerminalInteraction: { setPrimarySessionIfNeeded(itemId) },
          onRequestShowEditor: { setContentMode(.editor, for: item) },
          isMaximized: true,
          onToggleMaximize: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          isPrimarySession: isPrimary,
          showPrimaryIndicator: layoutMode != .single
        )
      case .monitored(_, let viewModel, let session, let state):
        let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
        let initialPrompt = viewModel.pendingPrompt(for: session.id)

        MonitoringCardView(
          session: session,
          state: state,
          planState: planState,
          cliConfiguration: viewModel.cliConfiguration,
          providerKind: item.providerKind,
          initialPrompt: initialPrompt,
          terminalKey: session.id,
          viewModel: viewModel,
          contentMode: editorContentModeBinding(for: item),
          selectedEditorFilePath: selectedEditorFilePathBinding(for: item),
          editorProjectPath: editorState(for: item).projectPath,
          editorNavigationRequest: editorState(for: item).navigationRequest,
          onStopMonitoring: {
            viewModel.stopMonitoring(session: session)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          onConnect: {
            _ = viewModel.connectToSession(session)
          },
          onCopySessionId: {
            viewModel.copySessionId(session)
          },
          onOpenSessionFile: {
            openSessionFile(for: session, viewModel: viewModel)
          },
          onRefreshTerminal: {
            viewModel.refreshTerminal(
              forKey: session.id,
              sessionId: session.id,
              projectPath: session.projectPath
            )
          },
          onInlineRequestSubmit: { prompt, sess in
            viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
          },
          onShowDiff: { session, projectPath in
            toggleSidePanel(
              .diff(sessionId: session.id, session: session, projectPath: projectPath),
              forItemID: itemId
            )
          },
          onShowPlan: { session, planState in
            toggleSidePanel(
              .plan(sessionId: session.id, session: session, planState: planState),
              forItemID: itemId
            )
          },
          onShowWebPreview: { session, projectPath, mode in
            presentWebPreviewInSidePanel(forItemID: itemId, session: session, projectPath: projectPath, mode: mode)
          },
          onShowMermaid: { session in
            toggleSidePanel(
              .mermaid(sessionId: session.id, session: session),
              forItemID: itemId
            )
          },
          onShowGitHub: { session, projectPath in
            toggleSidePanel(
              .gitHub(sessionId: session.id, session: session, projectPath: projectPath),
              forItemID: itemId
            )
          },
          onShowPendingChanges: { session, _ in
            toggleSidePanel(
              .edits(sessionId: session.id, session: session),
              forItemID: itemId
            )
          },
          onPromptConsumed: {
            viewModel.clearPendingPrompt(for: session.id)
          },
          onTerminalInteraction: { setPrimarySessionIfNeeded(itemId) },
          onRequestShowEditor: { setContentMode(.editor, for: item) },
          isMaximized: true,
          onToggleMaximize: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              maximizedSessionId = nil
            }
          },
          isPrimarySession: isPrimary,
          showPrimaryIndicator: layoutMode != .single
        )
      }
    }
  }

  private var allItems: [ProviderMonitoringItem] {
    pendingItems + monitoredItems
  }

  private var pendingItems: [ProviderMonitoringItem] {
    let claudePending = claudeViewModel.pendingHubSessions.map {
      ProviderMonitoringItem.pending(provider: .claude, viewModel: claudeViewModel, pending: $0)
    }
    let codexPending = codexViewModel.pendingHubSessions.map {
      ProviderMonitoringItem.pending(provider: .codex, viewModel: codexViewModel, pending: $0)
    }
    return claudePending + codexPending
  }

  private var monitoredItems: [ProviderMonitoringItem] {
    let claudeItems = claudeViewModel.monitoredSessions.map {
      ProviderMonitoringItem.monitored(provider: .claude, viewModel: claudeViewModel, session: $0.session, state: $0.state)
    }
    let codexItems = codexViewModel.monitoredSessions.map {
      ProviderMonitoringItem.monitored(provider: .codex, viewModel: codexViewModel, session: $0.session, state: $0.state)
    }
    return claudeItems + codexItems
  }

  private var groupedMonitoredSessions: [(modulePath: String, items: [ProviderMonitoringItem])] {
    makeItemSnapshot().groupedItems
  }

  private var flatSortedItems: [ProviderMonitoringItem] {
    makeItemSnapshot().flatSortedItems
  }

  private var effectivePrimaryItem: ProviderMonitoringItem? {
    makeItemSnapshot().effectivePrimaryItem
  }

  private var auxiliaryShellTarget: HubAuxiliaryShellTarget? {
    auxiliaryShellTarget(snapshot: makeItemSnapshot())
  }

  private func auxiliaryShellTarget(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> HubAuxiliaryShellTarget? {
    guard activeModuleLandingPath(snapshot: snapshot) == nil else { return nil }
    guard let item = snapshot.effectivePrimaryItem else { return nil }

    switch item {
    case .pending(let provider, let viewModel, let pending):
      return HubAuxiliaryShellTarget(
        context: .pending(pending: pending, providerKind: provider),
        viewModel: viewModel,
        displayName: pending.worktree.name
      )
    case .monitored(let provider, let viewModel, let session, _):
      return HubAuxiliaryShellTarget(
        context: .monitored(session: session, providerKind: provider),
        viewModel: viewModel,
        displayName: viewModel.displayName(for: session)
      )
    }
  }

  private var allSelectedRepositories: [SelectedRepository] {
    WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    ).sorted { $0.path < $1.path }
  }

  private var worktreeDisplayMode: WorktreeDisplayMode {
    WorktreeDisplayMode(rawValue: worktreeDisplayModeRawValue) ?? .parent
  }

  private var diffDisplayMode: DiffDisplayMode {
    DiffDisplayMode(rawValue: diffDisplayModeRawValue) ?? .inline
  }

  private var emptyStateViewModel: CLISessionsViewModel {
    if !claudeViewModel.selectedRepositories.isEmpty { return claudeViewModel }
    if !codexViewModel.selectedRepositories.isEmpty { return codexViewModel }
    return claudeViewModel
  }

  private func findModulePath(for item: ProviderMonitoringItem) -> String {
    WorktreeModuleResolver.modulePath(
      for: item.projectPath,
      repositories: allSelectedRepositories,
      mode: worktreeDisplayMode
    )
  }

  private func openSessionFile(for session: CLISession, viewModel: CLISessionsViewModel) {
    guard let fileURL = viewModel.sessionFileURL(for: session),
          let data = FileManager.default.contents(atPath: fileURL.path),
          let content = String(data: data, encoding: .utf8) else {
      return
    }

    if !content.isEmpty {
      sessionFileSheetItem = SessionFileSheetItem(
        session: session,
        fileName: fileURL.lastPathComponent,
        content: content
      )
    }
  }

  private func consumePendingFileOpen(
    from viewModel: CLISessionsViewModel,
    providerKind: SessionProviderKind
  ) {
    guard let pending = viewModel.pendingFileOpen else { return }
    defer {
      viewModel.pendingFileOpen = nil
    }

    guard let session = viewModel.allSessions.first(where: { $0.id == pending.sessionId })
      ?? viewModel.monitoredSessions.first(where: { $0.session.id == pending.sessionId })?.session
    else {
      Self.logFileOpen(
        "abort pendingFileOpen provider=\(providerKind.rawValue) missing session=\(pending.sessionId) file=\"\(pending.filePath)\""
      )
      return
    }

    let editorProjectPath = TerminalFileOpenProjectResolver.projectPath(
      forFile: pending.filePath,
      sessionProjectPath: session.projectPath,
      repositories: allSelectedRepositories
    )
    Self.logFileOpen(
      "consume pendingFileOpen provider=\(providerKind.rawValue) session=\(session.id) file=\"\(pending.filePath)\" sessionProject=\"\(session.projectPath)\" editorProject=\"\(editorProjectPath)\""
    )

    guard let item = allItems.first(where: { $0.providerKind == providerKind && $0.sessionId == pending.sessionId }) else {
      Self.logFileOpen(
        "abort pendingFileOpen provider=\(providerKind.rawValue) missing itemId for session=\(pending.sessionId)"
      )
      return
    }

    openFileInEditor(
      for: item.id,
      filePath: pending.filePath,
      projectPath: editorProjectPath,
      lineNumber: pending.lineNumber,
      makePrimary: true
    )
  }

  private static func logFileOpen(_ message: @autoclosure () -> String) {
    print("[AH-OPEN][AgentHub] \(message())")
  }

  private func ensurePrimarySelection(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>? = nil) {
    guard selectedModuleLandingPath == nil else {
      primarySessionId = nil
      return
    }

    let snapshot = snapshot ?? makeItemSnapshot()
    guard !snapshot.allItems.isEmpty else {
      primarySessionId = nil
      return
    }

    if let current = primarySessionId, snapshot.allItems.contains(where: { $0.id == current }) {
      return
    }

    primarySessionId = snapshot.effectivePrimaryItemID
  }

  private func setPrimarySessionIfNeeded(_ sessionId: String) {
    guard primarySessionId != sessionId else { return }
    primarySessionId = sessionId
  }

  private func shouldMountTerminal(for item: ProviderMonitoringItem, isPrimary: Bool) -> Bool {
    item.isPending || isPrimary || maximizedSessionId == item.id
  }

  private func toggleAuxiliaryShellDock() {
    guard auxiliaryShellTarget != nil else { return }
    withAnimation(auxiliaryShellToggleAnimation) {
      isAuxiliaryShellVisible.toggle()
    }
  }

  private func syncAuxiliaryShellDockState(target: HubAuxiliaryShellTarget? = nil) {
    guard isAuxiliaryShellVisible else { return }
    guard let target = target ?? auxiliaryShellTarget else {
      withAnimation(auxiliaryShellToggleAnimation) {
        isAuxiliaryShellVisible = false
      }
      return
    }
    guard target.context.isLaunchable else { return }
    target.viewModel.focusAuxiliaryShellTerminal(forKey: target.context.terminalKey)
  }

  @ViewBuilder
  private func auxiliaryShellDock(
    for target: HubAuxiliaryShellTarget,
    availableHeight: CGFloat
  ) -> some View {
    let maxHeight = max(auxiliaryShellMinHeight, availableHeight - auxiliaryShellMinMainContentHeight)
    let resolvedHeight = max(auxiliaryShellMinHeight, min(auxiliaryShellDefaultHeight, maxHeight))

    Group {
      if target.context.isLaunchable, let projectPath = target.context.projectPath {
        AuxiliaryShellTerminalView(
          terminalKey: target.context.terminalKey,
          projectPath: projectPath,
          viewModel: target.viewModel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: target.context.terminalKey) {
          target.viewModel.focusAuxiliaryShellTerminal(forKey: target.context.terminalKey)
        }
      } else {
        VStack(spacing: 10) {
          Image(systemName: "clock.arrow.circlepath")
            .font(.title2)
            .foregroundStyle(.secondary)

          Text(target.context.placeholderMessage ?? "Shell is waiting for a worktree path.")
            .font(.primaryCaption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      }
    }
    .frame(height: resolvedHeight, alignment: .top)
    .background(colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.92))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func listModeCard(
    for item: ProviderMonitoringItem,
    effectivePrimaryItemID: String? = nil
  ) -> some View {
    ResizableCardContainer(
      height: cardHeightBinding(for: item.id),
      metrics: listCardMetrics(for: item)
    ) {
      itemCardView(for: item, effectivePrimaryItemID: effectivePrimaryItemID)
    }
  }

  private func cardHeightBinding(for itemId: String) -> Binding<CGFloat> {
    Binding(
      get: { cardHeights[itemId] ?? 0 },
      set: { cardHeights[itemId] = $0 }
    )
  }

  private func editorState(for item: ProviderMonitoringItem) -> MonitoringEditorState {
    MonitoringEditorStateStore.state(
      for: item.id,
      defaultProjectPath: item.projectPath,
      in: editorStates
    )
  }

  private func editorContentModeBinding(for item: ProviderMonitoringItem) -> Binding<MonitoringCardContentMode> {
    Binding(
      get: { editorState(for: item).contentMode },
      set: { newValue in
        setContentMode(newValue, for: item)
      }
    )
  }

  private func selectedEditorFilePathBinding(for item: ProviderMonitoringItem) -> Binding<String?> {
    Binding(
      get: { editorState(for: item).selectedFilePath },
      set: { newValue in
        setPrimarySessionIfNeeded(item.id)
        editorStates = MonitoringEditorStateStore.setSelectedFilePath(
          newValue,
          for: item.id,
          defaultProjectPath: editorState(for: item).projectPath,
          in: editorStates
        )
      }
    )
  }

  private func syncEditorStates(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>? = nil) {
    let snapshot = snapshot ?? makeItemSnapshot()
    editorStates = MonitoringEditorStateStore.prune(
      editorStates,
      validItemIDs: Set(snapshot.itemIDs)
    )
  }

  private func setContentMode(_ contentMode: MonitoringCardContentMode, for item: ProviderMonitoringItem) {
    setPrimarySessionIfNeeded(item.id)
    editorStates = MonitoringEditorStateStore.setContentMode(
      contentMode,
      for: item.id,
      defaultProjectPath: editorState(for: item).projectPath,
      in: editorStates
    )

    if contentMode == .terminal {
      item.viewModel.focusTerminal(forKey: item.sessionId)
    }
  }

  private func togglePrimarySessionContentMode() {
    guard activeModuleLandingPath(snapshot: makeItemSnapshot()) == nil else { return }
    guard let item = effectivePrimaryItem else { return }
    let nextMode = MonitoringEditorStateStore.nextContentMode(
      after: editorState(for: item).contentMode,
      availableModes: availableContentModes(for: item)
    )
    setContentMode(nextMode, for: item)
  }

  private func availableContentModes(for item: ProviderMonitoringItem) -> [MonitoringCardContentMode] {
    MonitoringEditorStateStore.availableContentModes(
      diffDisplayMode: diffDisplayMode,
      diffAvailabilityStatus: item.viewModel.diffAvailabilityStatus(for: item.projectPath)
    )
  }

  private func showTerminalWithPrompt(
    _ prompt: String,
    for session: CLISession,
    itemID: String,
    viewModel: CLISessionsViewModel
  ) {
    if let item = allItems.first(where: { $0.id == itemID }) {
      setContentMode(.terminal, for: item)
    } else {
      viewModel.focusTerminal(forKey: session.id)
    }
    viewModel.showTerminalWithPrompt(for: session, prompt: prompt)
  }

  private func openFileInEditor(
    for itemID: String,
    filePath: String,
    projectPath: String,
    lineNumber: Int?,
    makePrimary: Bool
  ) {
    let result = MonitoringEditorStateStore.routeOpenFile(
      filePath,
      lineNumber: lineNumber,
      projectPath: projectPath,
      for: itemID,
      in: editorStates,
      currentPrimaryItemID: primarySessionId,
      makePrimary: makePrimary
    )
    editorStates = result.states
    if let primaryItemID = result.primaryItemID {
      primarySessionId = primaryItemID
    }
  }

  private func listCardMetrics(for item: ProviderMonitoringItem) -> ResizableCardMetrics {
    switch item {
    case .pending(let providerKind, _, _):
      return MonitoringCardView.listHeightMetrics(
        providerKind: providerKind,
        state: nil
      )
    case .monitored(let providerKind, _, _, let state):
      return MonitoringCardView.listHeightMetrics(
        providerKind: providerKind,
        state: state
      )
    }
  }

  private func activeModuleLandingPath(snapshot: MonitoringItemsSnapshot<ProviderMonitoringItem>) -> String? {
    ModuleLandingSelection.activeModulePath(
      selectedPath: selectedModuleLandingPath,
      repositories: allSelectedRepositories,
      itemProjectPaths: snapshot.allItems.map(\.projectPath),
      mode: worktreeDisplayMode
    )
  }
}

// MARK: - ModuleLandingView

private struct ModuleLandingView: View {
  let modulePath: String
  let onStartSession: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var moduleName: String {
    URL(fileURLWithPath: modulePath).lastPathComponent
  }

  var body: some View {
    VStack(spacing: 20) {
      Text("What should we build in \(moduleName)?")
        .font(.system(size: 31, weight: .regular))
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
        .lineLimit(nil)
        .minimumScaleFactor(0.65)
        .fixedSize(horizontal: false, vertical: true)

      Button(action: onStartSession) {
        HStack(spacing: 8) {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 13))
          Text("Start Session")
            .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(colorScheme == .dark ? .black : .white)
        .frame(height: 36)
        .padding(.horizontal, 18)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary)
        )
      }
      .buttonStyle(.plain)
      .help("Start a session in \(moduleName)")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 48)
    .padding(.vertical, 32)
  }
}

// MARK: - JSONL Filtering

/// Filters JSONL content for a clean transcript view
/// Shows: user questions, assistant text (truncated), tool names only
/// Removes: tool_result, thinking, file-history-snapshot, large content
private func filterJSONLContent(_ content: String) -> String {
  let lines = content.components(separatedBy: .newlines)
  var result: [String] = []
  let maxTextLength = 500

  for line in lines {
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    if trimmed.isEmpty { continue }

    guard let data = trimmed.data(using: .utf8) else { continue }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    guard let type = json["type"] as? String else { continue }

    // Codex format: event_msg with payload.type user_message/agent_message
    if type == "event_msg" {
      guard let payload = json["payload"] as? [String: Any],
            let eventType = payload["type"] as? String else { continue }

      if eventType == "user_message" || eventType == "agent_message" {
        let role = eventType == "user_message" ? "user" : "assistant"
        let message = (payload["message"] as? String) ?? ""
        let preview = String(message.prefix(maxTextLength))
        result.append("[\(role)] \(preview)")
      }
      continue
    }

    if type != "user" && type != "assistant" { continue }

    guard let message = json["message"] as? [String: Any] else { continue }
    guard let contentBlocks = message["content"] as? [[String: Any]] else { continue }

    var textParts: [String] = []
    var toolNames: [String] = []
    var hasOnlyToolResults = true

    for block in contentBlocks {
      guard let blockType = block["type"] as? String else { continue }

      switch blockType {
      case "text":
        hasOnlyToolResults = false
        if let text = block["text"] as? String {
          let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !cleaned.isEmpty {
            if cleaned.count > maxTextLength {
              textParts.append(String(cleaned.prefix(maxTextLength)) + "...")
            } else {
              textParts.append(cleaned)
            }
          }
        }

      case "tool_use":
        hasOnlyToolResults = false
        if let name = block["name"] as? String {
          var toolDesc = name
          if let input = block["input"] as? [String: Any] {
            if let filePath = input["file_path"] as? String {
              let fileName = (filePath as NSString).lastPathComponent
              toolDesc = "\(name)(\(fileName))"
            } else if let pattern = input["pattern"] as? String {
              let short = String(pattern.prefix(30))
              toolDesc = "\(name)(\(short))"
            } else if let command = input["command"] as? String {
              let short = String(command.prefix(40))
              toolDesc = "\(name)(\(short)...)"
            }
          }
          toolNames.append(toolDesc)
        }

      case "tool_result", "thinking":
        continue

      default:
        hasOnlyToolResults = false
      }
    }

    if hasOnlyToolResults { continue }

    var output = "[\(type.uppercased())]"

    if !textParts.isEmpty {
      output += " " + textParts.joined(separator: " ")
    }

    if !toolNames.isEmpty {
      output += " [Tools: " + toolNames.joined(separator: ", ") + "]"
    }

    if textParts.isEmpty && toolNames.isEmpty { continue }

    result.append(output)
  }

  if result.isEmpty {
    return "[No conversation content found - this session may only contain file history snapshots or tool results]"
  }

  return result.joined(separator: "\n\n")
}

// MARK: - MonitoringSessionFileSheetView

private struct MonitoringSessionFileSheetView: View {
  let session: CLISession
  let fileName: String
  let content: String
  let onDismiss: () -> Void

  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        HStack(spacing: 8) {
          Image(systemName: "doc.text.fill")
            .foregroundColor(.brandPrimary)
          Text(fileName)
            .font(.primaryDefault)
        }

        Spacer()

        Text(session.shortId)
          .font(.primaryCaption)
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.primaryCaption)
            .foregroundColor(.secondary)
        }

        Spacer()

        Button("Close") { onDismiss() }
      }
      .padding()
      .background(Color.surfaceElevated)

      Divider()

      PierreDiffView(
        oldContent: "",
        newContent: filterJSONLContent(content),
        fileName: fileName,
        diffStyle: $diffStyle,
        overflowMode: $overflowMode
      )
    }
    .frame(minWidth: 900, idealWidth: 1100, maxWidth: .infinity,
           minHeight: 700, idealHeight: 900, maxHeight: .infinity)
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
  }
}
