//
//  MonitoringPanelView.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

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
  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var editorStates: [String: MonitoringEditorState] = [:]
  @Binding var primarySessionId: String?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  public init(
    viewModel: CLISessionsViewModel,
    primarySessionId: Binding<String?>
  ) {
    self.viewModel = viewModel
    self._primarySessionId = primarySessionId
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
    guard let selectedId = effectivePrimarySessionId else { return [] }
    return allItems.filter { $0.id == selectedId }
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
      if visibleItems.isEmpty {
        emptyState
      } else {
        monitoredSessionsList
      }
    }
    .background(monitorContainerBackgroundColor)
    .frame(minWidth: 300)
    .sheet(item: $sessionFileSheetItem) { item in
      MonitoringSessionFileSheetView(
        session: item.session,
        fileName: item.fileName,
        content: item.content,
        onDismiss: { sessionFileSheetItem = nil }
      )
    }
    .onAppear {
      ensurePrimarySelection()
      syncEditorStates()
    }
    .onChange(of: allItems.map(\.id)) { _, _ in
      ensurePrimarySelection()
      syncEditorStates()
    }
  }

  private var monitorContainerBackgroundColor: Color {
    if runtimeTheme?.hasCustomBackgrounds == true {
      return Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    }
    return .clear
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle")
        .font(.largeTitle)
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Session Selected")
        .font(.heading)
        .foregroundColor(.secondary)

      (Text("Select a session from the sidebar or ") + Text("start a new one").bold() + Text(" to get started."))
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Monitored Sessions List

  @ViewBuilder
  private var monitoredSessionsList: some View {
    singleModeContent
  }

  // MARK: - Single Mode Content

  @ViewBuilder
  private var singleModeContent: some View {
    if let item = visibleItems.first {
      switch item {
      case .pending(let pending):
        let pendingId = "pending-\(pending.id.uuidString)"
        let monitoringItem = MonitoringItem.pending(pending)
        MonitoringCardView(
          session: pending.placeholderSession,
          state: nil,
          cliConfiguration: viewModel.cliConfiguration(for: viewModel.providerKind),
          providerKind: viewModel.providerKind,
          initialPrompt: pending.initialPrompt,
          initialInputText: pending.initialInputText,
          terminalKey: pendingId,
          viewModel: viewModel,
          contentMode: editorContentModeBinding(for: monitoringItem),
          selectedEditorFilePath: selectedEditorFilePathBinding(for: monitoringItem),
          editorProjectPath: editorState(for: monitoringItem).projectPath,
          editorNavigationRequest: editorState(for: monitoringItem).navigationRequest,
          dangerouslySkipPermissions: pending.dangerouslySkipPermissions,
          permissionModePlan: pending.permissionModePlan,
          worktreeName: pending.worktreeName,
          onStopMonitoring: {
            viewModel.cancelPendingSession(pending)
          },
          onConnect: { },
          onCopySessionId: { },
          onOpenSessionFile: { },
          onRefreshTerminal: { },
          onTerminalInteraction: { setPrimarySessionIfNeeded(pendingId) },
          onRequestShowEditor: { setContentMode(.editor, for: monitoringItem) },
          isPrimarySession: true,
          showPrimaryIndicator: false
        )
        .id(pendingId)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .monitored(let session, let state):
        let monitoringItem = MonitoringItem.monitored(session: session, state: state)
        let planState = state.flatMap { PlanState.from(activities: $0.recentActivities) }
        let initialPrompt = viewModel.pendingPrompt(for: session.id)

        MonitoringCardView(
          session: session,
          state: state,
          planState: planState,
          cliConfiguration: viewModel.cliConfiguration(for: viewModel.providerKind),
          providerKind: viewModel.providerKind,
          initialPrompt: initialPrompt,
          terminalKey: session.id,
          viewModel: viewModel,
          contentMode: editorContentModeBinding(for: monitoringItem),
          selectedEditorFilePath: selectedEditorFilePathBinding(for: monitoringItem),
          editorProjectPath: editorState(for: monitoringItem).projectPath,
          editorNavigationRequest: editorState(for: monitoringItem).navigationRequest,
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
          onTerminalInteraction: { setPrimarySessionIfNeeded(session.id) },
          onRequestShowEditor: { setContentMode(.editor, for: monitoringItem) },
          isPrimarySession: true,
          showPrimaryIndicator: false
        )
        .id(session.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  private func setPrimarySessionIfNeeded(_ sessionId: String) {
    guard primarySessionId != sessionId else { return }
    primarySessionId = sessionId
  }

  private func editorState(for item: MonitoringItem) -> MonitoringEditorState {
    MonitoringEditorStateStore.state(
      for: item.id,
      defaultProjectPath: item.projectPath,
      in: editorStates
    )
  }

  private func editorContentModeBinding(for item: MonitoringItem) -> Binding<MonitoringCardContentMode> {
    Binding(
      get: { editorState(for: item).contentMode },
      set: { newValue in
        setContentMode(newValue, for: item)
      }
    )
  }

  private func selectedEditorFilePathBinding(for item: MonitoringItem) -> Binding<String?> {
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

  private func syncEditorStates() {
    editorStates = MonitoringEditorStateStore.prune(
      editorStates,
      validItemIDs: Set(allItems.map(\.id))
    )
  }

  private func setContentMode(_ contentMode: MonitoringCardContentMode, for item: MonitoringItem) {
    setPrimarySessionIfNeeded(item.id)
    editorStates = MonitoringEditorStateStore.setContentMode(
      contentMode,
      for: item.id,
      defaultProjectPath: editorState(for: item).projectPath,
      in: editorStates
    )

    if contentMode == .terminal {
      viewModel.focusTerminal(forKey: item.id)
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
            .font(.primaryLarge)
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

      // Diff view showing filtered content
      PierreDiffView(
        oldContent: "",
        newContent: filterJSONLContent(content),
        fileName: fileName,
        diffStyle: $diffStyle,
        overflowMode: $overflowMode,
        renderOptions: .agentHubFileViewer
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

  MonitoringPanelView(viewModel: viewModel, primarySessionId: .constant(nil))
    .frame(width: 350, height: 500)
}
