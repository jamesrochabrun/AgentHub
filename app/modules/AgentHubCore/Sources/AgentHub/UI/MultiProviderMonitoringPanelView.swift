//
//  MultiProviderMonitoringPanelView.swift
//  AgentHub
//
//  Combines Claude + Codex monitored sessions into a single panel.
//

import AgentHubGitHub
import Foundation
import PierreDiffsSwift
import SwiftUI

// MARK: - SidePanelContent

private enum SidePanelContent: Equatable {
  case diff(sessionId: String, session: CLISession, projectPath: String)
  case plan(sessionId: String, session: CLISession, planState: PlanState)
  case webPreview(sessionId: String, session: CLISession, projectPath: String)
  case mermaid(sessionId: String, session: CLISession)
  case fileExplorer(sessionId: String, session: CLISession, projectPath: String, initialFilePath: String?, navigationId: UUID = UUID())
  case gitHub(sessionId: String, session: CLISession, projectPath: String)

  static func == (lhs: SidePanelContent, rhs: SidePanelContent) -> Bool {
    switch (lhs, rhs) {
    case (.diff(let id1, _, let p1), .diff(let id2, _, let p2)):
      return id1 == id2 && p1 == p2
    case (.plan(let id1, _, _), .plan(let id2, _, _)):
      return id1 == id2
    case (.webPreview(let id1, _, let p1), .webPreview(let id2, _, let p2)):
      return id1 == id2 && p1 == p2
    case (.mermaid(let id1, _), .mermaid(let id2, _)):
      return id1 == id2
    case (.fileExplorer(let id1, _, let p1, _, let n1), .fileExplorer(let id2, _, let p2, _, let n2)):
      return id1 == id2 && p1 == p2 && n1 == n2
    case (.gitHub(let id1, _, let p1), .gitHub(let id2, _, let p2)):
      return id1 == id2 && p1 == p2
    default: return false
    }
  }
}

extension SidePanelContent {
  var isFileExplorer: Bool {
    if case .fileExplorer = self { return true }
    return false
  }
}

// MARK: - FileExplorerPanelItem

private struct FileExplorerPanelItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
  let initialFilePath: String?
}

// MARK: - GitHubPopOutItem

private struct GitHubPopOutItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
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
  let onRequestStartSession: (String?) -> Void

  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var maximizedSessionId: String?
  @State private var sidePanelContent: SidePanelContent?
  // Persistent FileExplorer state – the view is never destroyed, only shown/hidden
  @State private var persistedFESession: CLISession? = nil
  @State private var persistedFEProjectPath: String = ""
  @State private var persistedFENavId: UUID = UUID()
  @State private var persistedFEInitPath: String? = nil
  @State private var availableDetailWidth: CGFloat = 0
  @Binding var primarySessionId: String?
  @AppStorage(AgentHubDefaults.hubLayoutMode)
  private var layoutModeRawValue: Int = LayoutMode.single.rawValue
  @AppStorage(AgentHubDefaults.hubPreviousLayoutMode)
  private var previousLayoutModeRawValue: Int = -1
  @AppStorage(AgentHubDefaults.flatSessionLayout)
  private var flatSessionLayout: Bool = false
  @AppStorage(AgentHubDefaults.fileExplorerAlwaysModal)
  private var fileExplorerAlwaysModal: Bool = false
  @State private var showQuickFilePicker = false
  @State private var fileExplorerPanelItem: FileExplorerPanelItem?
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

  private var canShowSidePanel: Bool {
    availableDetailWidth >= minimumWidthForEmbeddedSidePanel
  }

  private var minimumWidthForEmbeddedSidePanel: CGFloat {
    embeddedPrimaryContentMinWidth + embeddedSidePanelMinWidth + embeddedSidePanelHandleWidth
  }

  private var allowedEmbeddedSidePanelWidth: CGFloat {
    let availablePanelWidth = availableDetailWidth - embeddedPrimaryContentMinWidth - embeddedSidePanelHandleWidth
    return min(
      embeddedSidePanelMaxWidth,
      max(embeddedSidePanelMinWidth, availablePanelWidth)
    )
  }

  private var wantsEmbeddedSidePanelPresentation: Bool {
    layoutMode == .single
      && maximizedSessionId == nil
      && sidePanelContent != nil
      && !visibleItems.isEmpty
  }

  private var embeddedSidePanelTransition: AnyTransition {
    .asymmetric(
      insertion: .move(edge: .trailing).combined(with: .opacity),
      removal: .move(edge: .trailing).combined(with: .opacity)
    )
  }

  private var isEmbeddedSidePanelVisible: Bool {
    wantsEmbeddedSidePanelPresentation
      && canShowSidePanel
  }

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    primarySessionId: Binding<String?>,
    onEmbeddedSidePanelVisibilityChange: @escaping (Bool) -> Void = { _ in },
    onRequestStartSession: @escaping (String?) -> Void
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self._primarySessionId = primarySessionId
    self.onEmbeddedSidePanelVisibilityChange = onEmbeddedSidePanelVisibilityChange
    self.onRequestStartSession = onRequestStartSession
  }

  public var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        mainContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if isAuxiliaryShellVisible, let target = auxiliaryShellTarget {
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
      onEmbeddedSidePanelVisibilityChange(wantsEmbeddedSidePanelPresentation)
      syncAuxiliaryShellDockState()
    }
    .onChange(of: sidePanelContent) { _, newContent in
      // Sync persistent FileExplorer state when the panel switches to/from fileExplorer
      if case .fileExplorer(_, let session, let projectPath, let initPath, let navId) = newContent {
        persistedFESession = session
        persistedFEProjectPath = projectPath
        persistedFEInitPath = initPath
        persistedFENavId = navId
      }
    }
    .onChange(of: wantsEmbeddedSidePanelPresentation) { _, wantsPresentation in
      onEmbeddedSidePanelVisibilityChange(wantsPresentation)
    }
    .onChange(of: effectivePrimarySessionId) { _, _ in
      syncAuxiliaryShellDockState()
    }
    .onChange(of: isAuxiliaryShellVisible) { _, _ in
      syncAuxiliaryShellDockState()
    }
    .overlay {
      // Hidden Shift+P trigger for QuickFilePicker
      Button("") { showQuickFilePicker = true }
        .keyboardShortcut("p", modifiers: [.command])
        .frame(width: 0, height: 0)
        .hidden()
    }
    .floatingPanel(isPresented: $showQuickFilePicker, defaultSize: CGSize(width: 680, height: 640)) {
      if let primaryItem = allItems.first(where: { $0.id == effectivePrimarySessionId }) {
        QuickFilePickerView(
          isPresented: $showQuickFilePicker,
          projectPath: primaryItem.projectPath,
          onFileSelected: { path in
            showQuickFilePicker = false
            if case .monitored(_, _, let session, _) = primaryItem {
              if fileExplorerAlwaysModal {
                fileExplorerPanelItem = FileExplorerPanelItem(
                  session: session,
                  projectPath: primaryItem.projectPath,
                  initialFilePath: path
                )
              } else {
                sidePanelContent = .fileExplorer(
                  sessionId: session.id,
                  session: session,
                  projectPath: primaryItem.projectPath,
                  initialFilePath: path,
                  navigationId: UUID()
                )
              }
            }
          }
        )
      }
    }
    .modalPanel(
      item: $fileExplorerPanelItem,
      title: "File Explorer",
      autosaveName: "com.agenthub.panel.fileExplorer"
    ) { item in
      FileExplorerView(
        session: item.session,
        projectPath: item.projectPath,
        onDismiss: { fileExplorerPanelItem = nil },
        isEmbedded: false,
        initialFilePath: item.initialFilePath
      )
    }
    .modalPanel(
      item: $gitHubPopOutItem,
      title: "GitHub",
      autosaveName: "com.agenthub.panel.github"
    ) { item in
      GitHubPanelView(
        projectPath: item.projectPath,
        onDismiss: { gitHubPopOutItem = nil },
        isEmbedded: false,
        session: item.session
      )
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
      ensurePrimarySelection()
    }
    .onChange(of: allItems.map(\.id)) { _, _ in
      ensurePrimarySelection()
    }
    .onChange(of: effectivePrimarySessionId) { _, newId in
      guard let currentSidePanelContent = sidePanelContent else { return }

      // When switching sessions, update file explorer to new session's project path
      // instead of closing it.
      if currentSidePanelContent.isFileExplorer, let newId {
        if let item = allItems.first(where: { $0.id == newId }),
           case .monitored(_, _, let session, _) = item {
          sidePanelContent = .fileExplorer(
            sessionId: session.id,
            session: session,
            projectPath: session.projectPath,
            initialFilePath: nil,
            navigationId: UUID()
          )
        } else {
          sidePanelContent = nil
        }
      } else if case .webPreview(let sessionId, _, let projectPath) = currentSidePanelContent,
                sessionId.hasPrefix("pending-"),
                let newId,
                let item = allItems.first(where: { $0.id == newId }),
                case .monitored(_, _, let session, _) = item,
                session.projectPath == projectPath {
        sidePanelContent = .webPreview(
          sessionId: session.id,
          session: session,
          projectPath: session.projectPath
        )
      } else {
        sidePanelContent = nil
      }
    }
    .onChange(of: primarySessionId) { _, newId in
      guard let newId else { return }
      if let item = allItems.first(where: { $0.id == newId }) {
        item.viewModel.focusTerminal(forKey: item.sessionId)
      }
    }
    .onChange(of: canShowSidePanel) { _, canShow in
      if !canShow {
        withAnimation(.easeInOut(duration: 0.25)) {
          sidePanelContent = nil
        }
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

  private var auxiliaryShellToggleAnimation: Animation {
    accessibilityReduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.9)
  }

  private var auxiliaryShellDockTransition: AnyTransition {
    accessibilityReduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
  }

  @ViewBuilder
  private var mainContent: some View {
    if let maximizedId = maximizedSessionId {
      maximizedCardContent(for: maximizedId)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(maximizedContainerBackgroundColor)
    } else {
      mainContentBody
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }

  @ViewBuilder
  private var mainContentBody: some View {
    if isLoading {
      loadingState
    } else if allItems.isEmpty {
      emptyState
    } else {
      monitoredSessionsList
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
      Text("Restoring sessions...")
        .font(.primaryDefault)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    WelcomeView(
      viewModel: emptyStateViewModel,
      onStartSession: onRequestStartSession
    )
  }

  // MARK: - Monitored Sessions List

  @ViewBuilder
  private var monitoredSessionsList: some View {
    if layoutMode == .single {
      singleModeContent
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
            listModeContent
          } else {
            let columns = Array(repeating: GridItem(.flexible(), alignment: .top), count: layoutMode.columnCount)
            if flatSessionLayout {
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(flatSortedItems) { item in
                  itemCardView(for: item)
                }
              }
              .padding(12)
              .transition(.opacity)
            } else {
              LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
                monitoredSessionsGroupedContent
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
  private var listModeContent: some View {
    VStack(spacing: 12) {
      if flatSessionLayout {
        ForEach(flatSortedItems) { item in
          listModeCard(for: item)
        }
      } else {
        listModeGroupedContent
      }
    }
    .padding(12)
    .transition(.opacity)
  }

  // MARK: - Single Mode Content

  @ViewBuilder
  private var singleModeContent: some View {
    if let item = visibleItems.first {
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
            dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
            permissionModePlan: pending.permissionModePlan,
            worktreeName: pending.worktreeName,

            onStopMonitoring: { viewModel.cancelPendingSession(pending) },
            onConnect: { },
            onCopySessionId: { },
            onOpenSessionFile: { },
            onRefreshTerminal: { },
            onShowWebPreview: { session, projectPath in
              presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath)
            },
            onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
            isMaximized: false,
            onToggleMaximize: { },
            isPrimarySession: true,
            showPrimaryIndicator: false,
            isSidePanelOpen: sidePanelContent != nil
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
            onShowDiff: canShowSidePanel ? { session, projectPath in
              if case .diff(let sid, _, _) = sidePanelContent, sid == session.id {
                withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil }
              } else {
                sidePanelContent = .diff(sessionId: session.id, session: session, projectPath: projectPath)
              }
            } : nil,
            onShowPlan: canShowSidePanel ? { session, planState in
              if case .plan(let sid, _, _) = sidePanelContent, sid == session.id {
                withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil }
              } else {
                sidePanelContent = .plan(sessionId: session.id, session: session, planState: planState)
              }
            } : nil,
            onShowWebPreview: { session, projectPath in
              presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath)
            },
            onShowMermaid: canShowSidePanel ? { session in
              if case .mermaid(let sid, _) = sidePanelContent, sid == session.id {
                withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil }
              } else {
                sidePanelContent = .mermaid(sessionId: session.id, session: session)
              }
            } : nil,
            onShowFiles: (canShowSidePanel && !fileExplorerAlwaysModal) ? { session, projectPath in
              if case .fileExplorer(let sid, _, _, _, _) = sidePanelContent, sid == session.id {
                withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil }
              } else {
                sidePanelContent = .fileExplorer(
                  sessionId: session.id,
                  session: session,
                  projectPath: projectPath,
                  initialFilePath: nil
                )
              }
            } : nil,
            onShowGitHub: canShowSidePanel ? { session, projectPath in
              if case .gitHub(let sid, _, _) = sidePanelContent, sid == session.id {
                withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil }
              } else {
                sidePanelContent = .gitHub(sessionId: session.id, session: session, projectPath: projectPath)
              }
            } : nil,
            onPromptConsumed: {
              viewModel.clearPendingPrompt(for: session.id)
            },
            onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
            isMaximized: false,
            onToggleMaximize: { },
            isPrimarySession: true,
            showPrimaryIndicator: false,
            isSidePanelOpen: sidePanelContent != nil
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

      if let panelContent = sidePanelContent, !panelContent.isFileExplorer {
        ResizablePanelContainer(
          side: .trailing,
          minWidth: embeddedSidePanelMinWidth,
          maxWidth: allowedEmbeddedSidePanelWidth,
          defaultWidth: min(embeddedSidePanelDefaultWidth, allowedEmbeddedSidePanelWidth),
          userDefaultsKey: AgentHubDefaults.sidePanelWidth
        ) {
          sidePanelView(for: panelContent, viewModel: viewModel)
        }
        .transition(embeddedSidePanelTransition)
      }

      if sidePanelContent?.isFileExplorer == true, let feSession = persistedFESession {
        ResizablePanelContainer(
          side: .trailing,
          minWidth: embeddedSidePanelMinWidth,
          maxWidth: allowedEmbeddedSidePanelWidth,
          defaultWidth: min(embeddedSidePanelDefaultWidth, allowedEmbeddedSidePanelWidth),
          userDefaultsKey: AgentHubDefaults.sidePanelWidth
        ) {
          FileExplorerView(
            session: feSession,
            projectPath: persistedFEProjectPath,
            onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
            isEmbedded: true,
            initialFilePath: persistedFEInitPath
          )
          .id(persistedFENavId)
        }
        .transition(embeddedSidePanelTransition)
      }
    }
    .animation(.easeInOut(duration: 0.25), value: sidePanelContent)
    .animation(.easeInOut(duration: 0.25), value: isEmbeddedSidePanelVisible)
    .padding(12)
  }

  private func presentWebPreviewInSidePanel(forItemID itemID: String, session: CLISession, projectPath: String) {
    // TODO: Standardize this with the other auxiliary panel flows once web preview
    // selections can route context back into the main terminal across all layouts.
    withAnimation(.easeInOut(duration: 0.25)) {
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
    toggleWebPreviewSidePanel(for: session, projectPath: projectPath)
  }

  private func toggleWebPreviewSidePanel(for session: CLISession, projectPath: String) {
    if case .webPreview(let sessionId, _, _) = sidePanelContent, sessionId == session.id {
      closeEmbeddedSidePanel()
    } else {
      openEmbeddedSidePanel(.webPreview(sessionId: session.id, session: session, projectPath: projectPath))
    }
  }

  private func openEmbeddedSidePanel(_ content: SidePanelContent) {
    withAnimation(.easeInOut(duration: 0.25)) {
      sidePanelContent = content
    }
  }

  private func closeEmbeddedSidePanel() {
    withAnimation(.easeInOut(duration: 0.25)) {
      sidePanelContent = nil
    }
  }

  @ViewBuilder
  private func sidePanelView(for content: SidePanelContent, viewModel: CLISessionsViewModel) -> some View {
    switch content {
    case .diff(_, let session, let projectPath):
      GitDiffView(
        session: session,
        projectPath: projectPath,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: visibleItems.first?.providerKind ?? .claude,
        onInlineRequestSubmit: { prompt, sess in viewModel.showTerminalWithPrompt(for: sess, prompt: prompt) },
        isEmbedded: true
      )
    case .plan(_, let session, let planState):
      PlanView(
        session: session,
        planState: planState,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        isEmbedded: true,
        providerKind: visibleItems.first?.providerKind ?? .claude,
        onSendFeedback: { feedback, sess in
          viewModel.showTerminalWithPrompt(for: sess, prompt: feedback)
        }
      )
    case .webPreview(let sessionId, let session, let projectPath):
      WebPreviewView(
        session: session,
        projectPath: projectPath,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
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
        agentLocalhostURL: viewModel.monitorStates[sessionId]?.detectedLocalhostURL,
        monitorState: viewModel.monitorStates[sessionId]
      )
    case .mermaid(_, let session):
      MermaidDiagramView(
        session: session,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        isEmbedded: true
      )
    case .fileExplorer(_, let session, let projectPath, let initialFilePath, let navId):
      FileExplorerView(
        session: session,
        projectPath: projectPath,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        isEmbedded: true,
        initialFilePath: initialFilePath
      )
      .id(navId)
    case .gitHub(_, let session, let projectPath):
      GitHubPanelView(
        projectPath: projectPath,
        onDismiss: { withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil } },
        isEmbedded: true,
        session: session,
        onSendToSession: { prompt, sess in viewModel.showTerminalWithPrompt(for: sess, prompt: prompt) },
        onPopOut: {
          withAnimation(.easeInOut(duration: 0.25)) { sidePanelContent = nil }
          gitHubPopOutItem = GitHubPopOutItem(session: session, projectPath: projectPath)
        }
      )
    }
  }

  // MARK: - Single Card View

  @ViewBuilder
  private func itemCardView(for item: ProviderMonitoringItem) -> some View {
    let isPrimary = item.id == effectivePrimarySessionId
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
        dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
        permissionModePlan: pending.permissionModePlan,
        worktreeName: pending.worktreeName,
        onStopMonitoring: { viewModel.cancelPendingSession(pending) },
        onConnect: { },
        onCopySessionId: { },
        onOpenSessionFile: { },
        onRefreshTerminal: { },
        onShowWebPreview: { session, projectPath in
          presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath)
        },
        onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
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
        onShowWebPreview: { session, projectPath in
          presentWebPreviewInSidePanel(forItemID: item.id, session: session, projectPath: projectPath)
        },
        onPromptConsumed: {
          viewModel.clearPendingPrompt(for: session.id)
        },
        onTerminalInteraction: { setPrimarySessionIfNeeded(item.id) },
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
  private var listModeGroupedContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(groupedMonitoredSessions, id: \.modulePath) { group in
        VStack(alignment: .leading, spacing: 12) {
          ModuleSectionHeader(
            name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
            sessionCount: group.items.count
          )

          ForEach(group.items) { item in
            listModeCard(for: item)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var monitoredSessionsGroupedContent: some View {
    ForEach(groupedMonitoredSessions, id: \.modulePath) { group in
      Section(header: ModuleSectionHeader(
        name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
        sessionCount: group.items.count
      )) {
        ForEach(group.items) { item in
          itemCardView(for: item)
        }
      }
    }
  }

  private var effectivePrimarySessionId: String? {
    if let current = primarySessionId, allItems.contains(where: { $0.id == current }) {
      return current
    }
    return allItems.sorted { $0.timestamp > $1.timestamp }.first?.id
  }

  private var visibleItems: [ProviderMonitoringItem] {
    if layoutMode == .single {
      guard let selectedId = effectivePrimarySessionId else { return [] }
      return allItems.filter { $0.id == selectedId }
    }
    return allItems
  }

  // MARK: - Helpers

  @ViewBuilder
  private func maximizedCardContent(for itemId: String) -> some View {
    if let item = allItems.first(where: { $0.id == itemId }) {
      let isPrimary = item.id == effectivePrimarySessionId
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
          onShowWebPreview: { session, projectPath in
            presentWebPreviewInSidePanel(forItemID: itemId, session: session, projectPath: projectPath)
          },
          onTerminalInteraction: { setPrimarySessionIfNeeded(itemId) },
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
          onShowWebPreview: { session, projectPath in
            presentWebPreviewInSidePanel(forItemID: itemId, session: session, projectPath: projectPath)
          },
          onPromptConsumed: {
            viewModel.clearPendingPrompt(for: session.id)
          },
          onTerminalInteraction: { setPrimarySessionIfNeeded(itemId) },
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
    let grouped = Dictionary(grouping: visibleItems) { findModulePath(for: $0) }
    return grouped.sorted { $0.key < $1.key }
      .map { (modulePath: $0.key, items: $0.value.sorted { $0.timestamp > $1.timestamp }) }
  }

  private var flatSortedItems: [ProviderMonitoringItem] {
    groupedMonitoredSessions.flatMap { $0.items }
  }

  private var effectivePrimaryItem: ProviderMonitoringItem? {
    guard let selectedId = effectivePrimarySessionId else { return nil }
    return allItems.first(where: { $0.id == selectedId })
  }

  private var auxiliaryShellTarget: HubAuxiliaryShellTarget? {
    guard let item = effectivePrimaryItem else { return nil }

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
    var map: [String: SelectedRepository] = [:]
    for repo in claudeViewModel.selectedRepositories {
      map[repo.path] = repo
    }
    for repo in codexViewModel.selectedRepositories where map[repo.path] == nil {
      map[repo.path] = repo
    }
    return map.values.sorted { $0.path < $1.path }
  }

  private var emptyStateViewModel: CLISessionsViewModel {
    if !claudeViewModel.selectedRepositories.isEmpty { return claudeViewModel }
    if !codexViewModel.selectedRepositories.isEmpty { return codexViewModel }
    return claudeViewModel
  }

  private func findModulePath(for item: ProviderMonitoringItem) -> String {
    let itemPath = item.projectPath

    for repo in allSelectedRepositories {
      for worktree in repo.worktrees {
        if worktree.path == itemPath {
          return repo.path
        }
      }
    }
    return itemPath
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

  private func ensurePrimarySelection() {
    guard !allItems.isEmpty else {
      primarySessionId = nil
      return
    }

    if let current = primarySessionId, allItems.contains(where: { $0.id == current }) {
      return
    }

    primarySessionId = effectivePrimarySessionId
  }

  private func setPrimarySessionIfNeeded(_ sessionId: String) {
    guard primarySessionId != sessionId else { return }
    primarySessionId = sessionId
  }

  private func toggleAuxiliaryShellDock() {
    guard auxiliaryShellTarget != nil else { return }
    withAnimation(auxiliaryShellToggleAnimation) {
      isAuxiliaryShellVisible.toggle()
    }
  }

  private func syncAuxiliaryShellDockState() {
    guard isAuxiliaryShellVisible else { return }
    guard let target = auxiliaryShellTarget else {
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
  private func listModeCard(for item: ProviderMonitoringItem) -> some View {
    ResizableCardContainer(
      height: cardHeightBinding(for: item.id),
      metrics: listCardMetrics(for: item)
    ) {
      itemCardView(for: item)
    }
  }

  private func cardHeightBinding(for itemId: String) -> Binding<CGFloat> {
    Binding(
      get: { cardHeights[itemId] ?? 0 },
      set: { cardHeights[itemId] = $0 }
    )
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
