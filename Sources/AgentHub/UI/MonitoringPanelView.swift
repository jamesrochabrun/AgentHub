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

// MARK: - MonitoringPanelView

/// Right panel view showing all monitored sessions
public struct MonitoringPanelView: View {
  @Bindable var viewModel: CLISessionsViewModel
  let claudeClient: (any ClaudeCode)?
  @State private var sessionFileSheetItem: SessionFileSheetItem?
  @State private var useGridLayout: Bool = false

  public init(viewModel: CLISessionsViewModel, claudeClient: (any ClaudeCode)?) {
    self.viewModel = viewModel
    self.claudeClient = claudeClient
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      Divider()

      // Content
      if viewModel.monitoredSessionIds.isEmpty && viewModel.pendingHubSessions.isEmpty {
        emptyState
      } else {
        monitoredSessionsList
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
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Hub")
        .font(.title3.weight(.semibold))

      Spacer()

      // Layout toggle (only show when > 2 sessions total)
      let totalSessions = viewModel.monitoredSessionIds.count + viewModel.pendingHubSessions.count
      if totalSessions > 2 {
        HStack(spacing: 0) {
          Button(action: { withAnimation(.easeInOut(duration: 0.2)) { useGridLayout = false } }) {
            Image(systemName: "list.bullet")
              .font(.caption)
              .frame(width: 28, height: 20)
              .foregroundColor(!useGridLayout ? .white : .secondary)
              .background(!useGridLayout ? Color.brandPrimary : Color.clear)
              .clipShape(Capsule())
              .contentShape(Capsule())
          }
          .buttonStyle(.plain)

          Button(action: { withAnimation(.easeInOut(duration: 0.2)) { useGridLayout = true } }) {
            Image(systemName: "square.grid.2x2")
              .font(.caption)
              .frame(width: 28, height: 20)
              .foregroundColor(useGridLayout ? .white : .secondary)
              .background(useGridLayout ? Color.brandPrimary : Color.clear)
              .clipShape(Capsule())
              .contentShape(Capsule())
          }
          .buttonStyle(.plain)
        }
        .padding(2)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.2), value: useGridLayout)
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
      Image(systemName: "eye.slash")
        .font(.largeTitle)
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Sessions Monitored")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("Click the monitor button on a session to start tracking its activity in real-time.")
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Monitored Sessions List

  private var monitoredSessionsList: some View {
    ScrollView {
      if useGridLayout {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          monitoredSessionsContent
        }
        .padding(12)
      } else {
        LazyVStack(spacing: 12) {
          monitoredSessionsContent
        }
        .padding(12)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: useGridLayout)
  }

  @ViewBuilder
  private var monitoredSessionsContent: some View {
    // Pending sessions (new sessions starting in Hub)
    ForEach(viewModel.pendingHubSessions) { pending in
      MonitoringCardView(
        session: pending.placeholderSession,
        state: nil,
        claudeClient: claudeClient,
        showTerminal: true,
        onToggleTerminal: { _ in },
        onStopMonitoring: {
          viewModel.cancelPendingSession(pending)
        },
        onConnect: { },
        onCopySessionId: { },
        onOpenSessionFile: { }
      )
    }

    // Monitored sessions (existing sessions)
    ForEach(viewModel.monitoredSessions, id: \.session.id) { item in
      let codeChangesState = item.state.map {
        CodeChangesState.from(activities: $0.recentActivities)
      }

      MonitoringCardView(
        session: item.session,
        state: item.state,
        codeChangesState: codeChangesState,
        claudeClient: claudeClient,
        showTerminal: viewModel.sessionsWithTerminalView.contains(item.session.id),
        onToggleTerminal: { show in
          viewModel.setTerminalView(for: item.session.id, show: show)
        },
        onStopMonitoring: {
          viewModel.stopMonitoring(session: item.session)
        },
        onConnect: {
          if let error = viewModel.connectToSession(item.session) {
            print("Failed to connect: \(error.localizedDescription)")
          }
        },
        onCopySessionId: {
          viewModel.copySessionId(item.session)
        },
        onOpenSessionFile: {
          openSessionFile(for: item.session)
        }
      )
    }
  }

  // MARK: - Session File Opening

  private func openSessionFile(for session: CLISession) {
    // Build path: ~/.claude/projects/{encoded-project-path}/{sessionId}.jsonl
    let encodedPath = session.projectPath.replacingOccurrences(of: "/", with: "-")
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let filePath = homeDir
      .appendingPathComponent(".claude/projects")
      .appendingPathComponent(encodedPath)
      .appendingPathComponent("\(session.id).jsonl")

    // Read file content
    if let data = FileManager.default.contents(atPath: filePath.path),
       let content = String(data: data, encoding: .utf8) {
      sessionFileSheetItem = SessionFileSheetItem(
        session: session,
        fileName: "\(session.id).jsonl",
        content: content
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
  let viewModel = CLISessionsViewModel(monitorService: service)

  MonitoringPanelView(viewModel: viewModel, claudeClient: nil)
    .frame(width: 350, height: 500)
}
