//
//  MonitoringPanelView.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

import ClaudeCodeSDK
import PierreDiffsSwift
import SwiftUI

// MARK: - SessionFileSheetItem

/// Identifiable wrapper for session file sheet
private struct SessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

// MARK: - LayoutMode

/// Layout modes for the monitoring panel
private enum LayoutMode: Int, CaseIterable {
  case list = 0
  case twoColumn = 1
  case threeColumn = 2

  var columnCount: Int {
    switch self {
    case .list: return 1
    case .twoColumn: return 2
    case .threeColumn: return 3
    }
  }

  var icon: String {
    switch self {
    case .list: return "list.bullet"
    case .twoColumn: return "square.grid.2x2"
    case .threeColumn: return "square.grid.3x3"
    }
  }
}

// MARK: - ModuleSectionHeader

/// Section header for grouping sessions by module
private struct ModuleSectionHeader: View {
  let name: String
  let sessionCount: Int

  var body: some View {
    HStack {
      Text(name)
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.secondary)
      Spacer()
      Text("\(sessionCount)")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 4)
    .padding(.top, 6)
    .padding(.bottom, 10)
  }
}

// MARK: - MonitoringItem

/// Unified type for both pending and monitored sessions in the monitoring panel
private enum MonitoringItem: Identifiable {
  case pending(PendingHubSession)
  case monitored(session: CLISession, state: SessionMonitorState?)

  var id: String {
    switch self {
    case .pending(let p): return "pending-\(p.id.uuidString)"
    case .monitored(let session, _): return session.id
    }
  }

  var projectPath: String {
    switch self {
    case .pending(let p): return p.worktree.path
    case .monitored(let session, _): return session.projectPath
    }
  }
}

// MARK: - MonitoringPanelView

/// Right panel view showing all monitored sessions
public struct MonitoringPanelView: View {
  @Bindable var viewModel: CLISessionsViewModel
  let claudeClient: (any ClaudeCode)?
  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var layoutModeRawValue: Int = LayoutMode.list.rawValue
  @State private var maximizedSessionId: String?
  /// Primary session shown in Single mode and highlighted in All mode
  @Binding var primarySessionId: String?
  @AppStorage(AgentHubDefaults.hubSessionDisplayMode)
  private var displayModeRawValue: Int = HubSessionDisplayMode.single.rawValue
  @Environment(\.colorScheme) private var colorScheme

  private var layoutMode: LayoutMode {
    get { LayoutMode(rawValue: layoutModeRawValue) ?? .list }
  }

  private var displayMode: HubSessionDisplayMode {
    HubSessionDisplayMode(rawValue: displayModeRawValue) ?? .single
  }

  public init(
    viewModel: CLISessionsViewModel,
    claudeClient: (any ClaudeCode)?,
    primarySessionId: Binding<String?>
  ) {
    self.viewModel = viewModel
    self.claudeClient = claudeClient
    self._primarySessionId = primarySessionId
  }

  /// Finds the main module path for an item (maps worktree paths to their parent repository)
  private func findModulePath(for item: MonitoringItem) -> String {
    let itemPath: String
    switch item {
    case .pending(let p): itemPath = p.worktree.path
    case .monitored(let s, _): itemPath = s.projectPath
    }

    // Find which SelectedRepository contains this path
    for repo in viewModel.selectedRepositories {
      for worktree in repo.worktrees {
        if worktree.path == itemPath {
          return repo.path  // Return main module path
        }
      }
    }
    return itemPath  // Fallback to original path
  }

  private var allItems: [MonitoringItem] {
    var items: [MonitoringItem] = []

    for pending in viewModel.pendingHubSessions {
      items.append(.pending(pending))
    }

    for item in viewModel.monitoredSessions {
      items.append(.monitored(session: item.session, state: item.state))
    }

    return items
  }

  private var effectivePrimarySessionId: String? {
    if let current = primarySessionId, allItems.contains(where: { $0.id == current }) {
      return current
    }
    return allItems.sorted { timestamp(for: $0) > timestamp(for: $1) }.first?.id
  }

  private var visibleItems: [MonitoringItem] {
    switch displayMode {
    case .allMonitored:
      return allItems
    case .single:
      guard let selectedId = effectivePrimarySessionId else { return [] }
      return allItems.filter { $0.id == selectedId }
    }
  }

  /// All sessions (pending + monitored) grouped by module (main repository path)
  private var groupedMonitoredSessions: [(modulePath: String, items: [MonitoringItem])] {
    let grouped = Dictionary(grouping: visibleItems) { findModulePath(for: $0) }
    return grouped.sorted { $0.key < $1.key }
      .map { (modulePath: $0.key, items: $0.value.sorted { item1, item2 in
        // Sort by timestamp descending (newest first)
        timestamp(for: item1) > timestamp(for: item2)
      })}
  }

  /// Helper to get timestamp for sorting MonitoringItems
  private func timestamp(for item: MonitoringItem) -> Date {
    switch item {
    case .pending(let p): return p.startedAt
    case .monitored(let session, _): return session.lastActivityAt
    }
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Show maximized view OR normal list
      if let maximizedId = maximizedSessionId {
        // Maximized single card view
        maximizedCardContent(for: maximizedId)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(white: colorScheme == .dark ? 0.07 : 0.92))
      } else {
        // Normal list view
        header

        Divider()

        if visibleItems.isEmpty {
          emptyState
        } else {
          monitoredSessionsList
        }
      }
    }
    .frame(minWidth: 300)
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
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Hub")
        .font(.title3.weight(.semibold))

      Spacer()

      // Layout toggle (only show when > 2 sessions total)
      let totalSessions = viewModel.monitoredSessionIds.count + viewModel.pendingHubSessions.count
      if displayMode == .allMonitored, totalSessions >= 2 {
        HStack(spacing: 4) {
          ForEach(LayoutMode.allCases, id: \.rawValue) { mode in
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { layoutModeRawValue = mode.rawValue } }) {
              Image(systemName: mode.icon)
                .font(.caption)
                .frame(width: 28, height: 22)
                .foregroundColor(layoutMode == mode ? .brandPrimary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.2), value: layoutMode)
      }

      // Count badge (includes both monitored and pending)
      if totalSessions > 0 {
        Text("\(totalSessions)")
          .font(.system(.caption, design: .rounded).weight(.semibold))
          .monospacedDigit()
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .padding(.vertical, DesignTokens.Spacing.xs)
          .background(
            Capsule()
              .fill(Color.brandPrimary.opacity(0.15))
          )
          .foregroundColor(.brandPrimary)
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.vertical, DesignTokens.Spacing.md)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.largeTitle)
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Session Selected")
        .font(.headline)
        .foregroundColor(.secondary)

      (Text("Select a session from the sidebar or ") + Text("start a new one").bold() + Text(" to get started."))
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Maximized Card Content

  @ViewBuilder
  private func maximizedCardContent(for sessionId: String) -> some View {
    let isPrimary = sessionId == effectivePrimarySessionId
    // Find the session to maximize (check both pending and monitored)
    if let pending = viewModel.pendingHubSessions.first(where: { "pending-\($0.id.uuidString)" == sessionId }) {
      MonitoringCardView(
        session: pending.placeholderSession,
        state: nil,
        claudeClient: claudeClient,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: viewModel.providerKind,
        showTerminal: true,
        initialPrompt: pending.initialPrompt,
        terminalKey: "pending-\(pending.id.uuidString)",
        viewModel: viewModel,
        dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
        onToggleTerminal: { _ in },
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
        isMaximized: true,
        onToggleMaximize: {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            maximizedSessionId = nil
          }
        },
        isPrimarySession: isPrimary,
        showPrimaryIndicator: displayMode == .allMonitored
      )
    } else if let item = viewModel.monitoredSessions.first(where: { $0.session.id == sessionId }) {
      let planState = item.state.flatMap {
        PlanState.from(activities: $0.recentActivities)
      }
      let initialPrompt = viewModel.pendingPrompt(for: item.session.id)

      MonitoringCardView(
        session: item.session,
        state: item.state,
        planState: planState,
        claudeClient: claudeClient,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: viewModel.providerKind,
        showTerminal: viewModel.sessionsWithTerminalView.contains(item.session.id),
        initialPrompt: initialPrompt,
        terminalKey: item.session.id,
        viewModel: viewModel,
        onToggleTerminal: { show in
          viewModel.setTerminalView(for: item.session.id, show: show)
        },
        onStopMonitoring: {
          viewModel.stopMonitoring(session: item.session)
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            maximizedSessionId = nil
          }
        },
        onConnect: {
          _ = viewModel.connectToSession(item.session)
        },
        onCopySessionId: {
          viewModel.copySessionId(item.session)
        },
        onOpenSessionFile: {
          openSessionFile(for: item.session)
        },
        onRefreshTerminal: {
          viewModel.refreshTerminal(
            forKey: item.session.id,
            sessionId: item.session.id,
            projectPath: item.session.projectPath
          )
        },
        onInlineRequestSubmit: { prompt, session in
          viewModel.showTerminalWithPrompt(for: session, prompt: prompt)
        },
        onPromptConsumed: {
          viewModel.clearPendingPrompt(for: item.session.id)
        },
        isMaximized: true,
        onToggleMaximize: {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            maximizedSessionId = nil
          }
        },
        isPrimarySession: isPrimary,
        showPrimaryIndicator: displayMode == .allMonitored
      )
    }
  }

  // MARK: - Monitored Sessions List

  @ViewBuilder
  private var monitoredSessionsList: some View {
    if displayMode == .single {
      singleModeContent
    } else {
      ScrollView {
        if layoutMode == .list {
          LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
            monitoredSessionsGroupedContent
          }
          .padding(12)
        } else {
          let columns = Array(repeating: GridItem(.flexible(), alignment: .top), count: layoutMode.columnCount)
          LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
            monitoredSessionsGroupedContent
          }
          .padding(12)
        }
      }
      .animation(.easeInOut(duration: 0.2), value: layoutMode)
      .onChange(of: allItems.count) { _, newCount in
        if newCount < 2 && layoutMode != .list {
          withAnimation(.easeInOut(duration: 0.2)) {
            layoutModeRawValue = LayoutMode.list.rawValue
          }
        }
      }
    }
  }

  // MARK: - Single Mode Content

  @ViewBuilder
  private var singleModeContent: some View {
    if let item = visibleItems.first {
      switch item {
      case .pending(let pending):
        let pendingId = "pending-\(pending.id.uuidString)"
        MonitoringCardView(
          session: pending.placeholderSession,
          state: nil,
          claudeClient: claudeClient,
          cliConfiguration: viewModel.cliConfiguration,
          providerKind: viewModel.providerKind,
          showTerminal: true,
          initialPrompt: pending.initialPrompt,
          terminalKey: pendingId,
          viewModel: viewModel,
          dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
          onToggleTerminal: { _ in },
          onStopMonitoring: {
            viewModel.cancelPendingSession(pending)
          },
          onConnect: { },
          onCopySessionId: { },
          onOpenSessionFile: { },
          onRefreshTerminal: { },
          isMaximized: false,
          onToggleMaximize: { },
          isPrimarySession: true,
          showPrimaryIndicator: false
        )
        .id(pendingId)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)

      case .monitored(let session, let state):
        let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
        let initialPrompt = viewModel.pendingPrompt(for: session.id)

        MonitoringCardView(
          session: session,
          state: state,
          planState: planState,
          claudeClient: claudeClient,
          cliConfiguration: viewModel.cliConfiguration,
          providerKind: viewModel.providerKind,
          showTerminal: viewModel.sessionsWithTerminalView.contains(session.id),
          initialPrompt: initialPrompt,
          terminalKey: session.id,
          viewModel: viewModel,
          onToggleTerminal: { show in
            viewModel.setTerminalView(for: session.id, show: show)
          },
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
            openSessionFile(for: session)
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
          onPromptConsumed: {
            viewModel.clearPendingPrompt(for: session.id)
          },
          isMaximized: false,
          onToggleMaximize: { },
          isPrimarySession: true,
          showPrimaryIndicator: false
        )
        .id(session.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
      }
    }
  }

  @ViewBuilder
  private var monitoredSessionsContent: some View {
    // Pending sessions (new sessions starting in Hub)
    ForEach(viewModel.pendingHubSessions) { pending in
      let pendingId = "pending-\(pending.id.uuidString)"
      let isPrimary = pendingId == effectivePrimarySessionId
      MonitoringCardView(
        session: pending.placeholderSession,
        state: nil,
        claudeClient: claudeClient,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: viewModel.providerKind,
        showTerminal: true,
        initialPrompt: pending.initialPrompt,
        terminalKey: pendingId,
        viewModel: viewModel,
        dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
        onToggleTerminal: { _ in },
        onStopMonitoring: {
          viewModel.cancelPendingSession(pending)
        },
        onConnect: { },
        onCopySessionId: { },
        onOpenSessionFile: { },
        onRefreshTerminal: { },
        isMaximized: maximizedSessionId == pendingId,
        onToggleMaximize: {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            maximizedSessionId = maximizedSessionId == pendingId ? nil : pendingId
          }
        },
        isPrimarySession: isPrimary,
        showPrimaryIndicator: displayMode == .allMonitored
      )
    }

    // Monitored sessions (existing sessions)
    ForEach(viewModel.monitoredSessions, id: \.session.id) { item in
      let isPrimary = item.session.id == effectivePrimarySessionId
      let planState = item.state.flatMap {
        PlanState.from(activities: $0.recentActivities)
      }
      // Read pending prompt (read-only, safe during view body)
      let initialPrompt = viewModel.pendingPrompt(for: item.session.id)

      MonitoringCardView(
        session: item.session,
        state: item.state,
        planState: planState,
        claudeClient: claudeClient,
        cliConfiguration: viewModel.cliConfiguration,
        providerKind: viewModel.providerKind,
        showTerminal: viewModel.sessionsWithTerminalView.contains(item.session.id),
        initialPrompt: initialPrompt,
        terminalKey: item.session.id,
        viewModel: viewModel,
        onToggleTerminal: { show in
          viewModel.setTerminalView(for: item.session.id, show: show)
        },
        onStopMonitoring: {
          viewModel.stopMonitoring(session: item.session)
        },
        onConnect: {
          _ = viewModel.connectToSession(item.session)
        },
        onCopySessionId: {
          viewModel.copySessionId(item.session)
        },
        onOpenSessionFile: {
          openSessionFile(for: item.session)
        },
        onRefreshTerminal: {
          viewModel.refreshTerminal(
            forKey: item.session.id,
            sessionId: item.session.id,
            projectPath: item.session.projectPath
          )
        },
        onInlineRequestSubmit: { prompt, session in
          viewModel.showTerminalWithPrompt(for: session, prompt: prompt)
        },
        onPromptConsumed: {
          viewModel.clearPendingPrompt(for: item.session.id)
        },
        isMaximized: maximizedSessionId == item.session.id,
        onToggleMaximize: {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            maximizedSessionId = maximizedSessionId == item.session.id ? nil : item.session.id
          }
        },
        isPrimarySession: isPrimary,
        showPrimaryIndicator: displayMode == .allMonitored
      )
    }
  }

  // MARK: - Grouped Content by Module

  @ViewBuilder
  private var monitoredSessionsGroupedContent: some View {
    // All sessions grouped by module (pending + monitored combined)
    ForEach(groupedMonitoredSessions, id: \.modulePath) { group in
      Section(header: ModuleSectionHeader(
        name: URL(fileURLWithPath: group.modulePath).lastPathComponent,
        sessionCount: group.items.count
      )) {
        ForEach(group.items) { item in
          switch item {
          case .pending(let pending):
            let pendingId = "pending-\(pending.id.uuidString)"
            let isPrimary = pendingId == effectivePrimarySessionId
            MonitoringCardView(
              session: pending.placeholderSession,
              state: nil,
              claudeClient: claudeClient,
              cliConfiguration: viewModel.cliConfiguration,
              providerKind: viewModel.providerKind,
              showTerminal: true,
              initialPrompt: pending.initialPrompt,
              terminalKey: pendingId,
              viewModel: viewModel,
              dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
              onToggleTerminal: { _ in },
              onStopMonitoring: {
                viewModel.cancelPendingSession(pending)
              },
              onConnect: { },
              onCopySessionId: { },
              onOpenSessionFile: { },
              onRefreshTerminal: { },
              isMaximized: maximizedSessionId == pendingId,
              onToggleMaximize: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                  maximizedSessionId = maximizedSessionId == pendingId ? nil : pendingId
                }
              },
              isPrimarySession: isPrimary,
              showPrimaryIndicator: displayMode == .allMonitored
            )

          case .monitored(let session, let state):
            let isPrimary = session.id == effectivePrimarySessionId
            let planState = state.flatMap {
              PlanState.from(activities: $0.recentActivities)
            }
            let initialPrompt = viewModel.pendingPrompt(for: session.id)

            MonitoringCardView(
              session: session,
              state: state,
              planState: planState,
              claudeClient: claudeClient,
              cliConfiguration: viewModel.cliConfiguration,
              providerKind: viewModel.providerKind,
              showTerminal: viewModel.sessionsWithTerminalView.contains(session.id),
              initialPrompt: initialPrompt,
              terminalKey: session.id,
              viewModel: viewModel,
              onToggleTerminal: { show in
                viewModel.setTerminalView(for: session.id, show: show)
              },
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
                openSessionFile(for: session)
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
              onPromptConsumed: {
                viewModel.clearPendingPrompt(for: session.id)
              },
              isMaximized: maximizedSessionId == session.id,
              onToggleMaximize: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                  maximizedSessionId = maximizedSessionId == session.id ? nil : session.id
                }
              },
              isPrimarySession: isPrimary,
              showPrimaryIndicator: displayMode == .allMonitored
            )
          }
        }
      }
    }
  }

  // MARK: - Session File Opening

  private func openSessionFile(for session: CLISession) {
    guard let fileURL = viewModel.sessionFileURL(for: session),
          let data = FileManager.default.contents(atPath: fileURL.path),
          let content = String(data: data, encoding: .utf8) else {
      return
    }

    // Read file content
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

    // Skip file-history-snapshot, summary, etc.
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

    // Skip entries that only had tool_result blocks
    if hasOnlyToolResults { continue }

    // Build clean output line
    var output = "[\(type.uppercased())]"

    if !textParts.isEmpty {
      output += " " + textParts.joined(separator: " ")
    }

    if !toolNames.isEmpty {
      output += " [Tools: " + toolNames.joined(separator: ", ") + "]"
    }

    // Only add if we have meaningful content
    if textParts.isEmpty && toolNames.isEmpty { continue }

    result.append(output)
  }

  if result.isEmpty {
    return "[No conversation content found - this session may only contain file history snapshots or tool results]"
  }

  return result.joined(separator: "\n\n")
}

// MARK: - MonitoringSessionFileSheetView

/// Sheet view that displays session JSONL content using PierreDiffView
private struct MonitoringSessionFileSheetView: View {
  let session: CLISession
  let fileName: String
  let content: String
  let onDismiss: () -> Void

  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        HStack(spacing: 8) {
          Image(systemName: "doc.text.fill")
            .foregroundColor(.brandPrimary)
          Text(fileName)
            .font(.system(.headline, design: .monospaced))
        }

        Spacer()

        Text(session.shortId)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()

        Button("Close") { onDismiss() }
      }
      .padding()
      .background(Color.surfaceElevated)

      Divider()

      // Diff view showing filtered content
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

// MARK: - Preview

#Preview {
  let service = CLISessionMonitorService()
  let viewModel = CLISessionsViewModel(
    monitorService: service,
    fileWatcher: SessionFileWatcher(),
    searchService: GlobalSearchService(),
    cliConfiguration: .claudeDefault,
    providerKind: .claude
  )

  MonitoringPanelView(viewModel: viewModel, claudeClient: nil, primarySessionId: .constant(nil))
    .frame(width: 350, height: 500)
}
