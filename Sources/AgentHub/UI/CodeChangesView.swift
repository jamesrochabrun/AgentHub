//
//  CodeChangesView.swift
//  AgentHub
//
//  Created by Assistant on 1/13/26.
//

import SwiftUI
import PierreDiffsSwift

// MARK: - CodeChangesView

/// Full-screen sheet showing code diffs for a session
public struct CodeChangesView: View {
  let session: CLISession
  let codeChangesState: CodeChangesState
  let onDismiss: () -> Void

  @State private var selectedChangeId: UUID?
  @State private var diffInputs: [UUID: DiffInputData] = [:]
  @State private var loadingStates: [UUID: Bool] = [:]
  @State private var errorMessages: [UUID: String] = [:]
  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap

  public init(
    session: CLISession,
    codeChangesState: CodeChangesState,
    onDismiss: @escaping () -> Void
  ) {
    self.session = session
    self.codeChangesState = codeChangesState
    self.onDismiss = onDismiss
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      Divider()

      // Content
      if codeChangesState.changes.isEmpty {
        emptyState
      } else {
        HSplitView {
          // File list sidebar
          fileListSidebar
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

          // Diff viewer
          diffViewer
        }
      }
    }
    .frame(minWidth: 1200, idealWidth: .infinity, maxWidth: .infinity,
           minHeight: 800, idealHeight: .infinity, maxHeight: .infinity)
    .onAppear {
      // Auto-select first change
      if selectedChangeId == nil, let first = codeChangesState.changes.first {
        selectedChangeId = first.id
        loadDiff(for: first)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      HStack(spacing: 8) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .font(.title3)
          .foregroundColor(.brandPrimary)

        Text("Code Changes")
          .font(.title3.weight(.semibold))

        Text("(\(codeChangesState.changeCount))")
          .font(.title3)
          .foregroundColor(.secondary)
      }

      Spacer()

      // Session info
      HStack(spacing: 8) {
        Text(session.shortId)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      Button("Close") {
        onDismiss()
      }
      .keyboardShortcut(.escape)
    }
    .padding()
    .background(Color.surfaceElevated)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.secondary.opacity(0.5))

      Text("No Code Changes")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("This session hasn't made any Edit, Write, or MultiEdit operations yet.")
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - File List Sidebar

  private var fileListSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack {
        Text("Changes")
          .font(.headline)
        Spacer()
      }
      .padding()

      Divider()

      // File list
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(codeChangesState.changes) { change in
            CodeChangeRow(
              change: change,
              isSelected: selectedChangeId == change.id,
              onSelect: {
                selectedChangeId = change.id
                loadDiff(for: change)
              }
            )
          }
        }
        .padding(8)
      }
    }
  }

  // MARK: - Diff Viewer

  @ViewBuilder
  private var diffViewer: some View {
    if let selectedId = selectedChangeId {
      if loadingStates[selectedId] == true {
        // Loading state
        VStack {
          ProgressView()
          Text("Loading diff...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = errorMessages[selectedId] {
        // Error state
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundColor(.red)
          Text(error)
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
      } else if let diffData = diffInputs[selectedId] {
        DiffViewWithHeader(
          oldContent: diffData.oldContent,
          newContent: diffData.newContent,
          fileName: URL(fileURLWithPath: diffData.fileName).lastPathComponent,
          diffStyle: $diffStyle,
          overflowMode: $overflowMode
        )
        .frame(minHeight: 400)
        .id(selectedId)
      } else {
        // No diff loaded
        Text("Select a change to view")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      Text("Select a change to view")
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Load Diff

  private func loadDiff(for change: CodeChangeEntry) {
    // Skip if already loaded
    if diffInputs[change.id] != nil { return }

    loadingStates[change.id] = true

    Task {
      do {
        let diffData = try await generateDiffData(for: change.input, projectPath: session.projectPath)
        await MainActor.run {
          diffInputs[change.id] = diffData
          loadingStates[change.id] = false
        }
      } catch {
        await MainActor.run {
          errorMessages[change.id] = error.localizedDescription
          loadingStates[change.id] = false
        }
      }
    }
  }

  private func generateDiffData(
    for input: CodeChangeInput,
    projectPath: String
  ) async throws -> DiffInputData {
    // Don't read from disk - files are already modified
    // Use captured tool parameters directly
    switch input.toolType {
    case .edit:
      // Show the edit diff (old_string -> new_string)
      return DiffInputData(
        oldContent: input.oldString ?? "",
        newContent: input.newString ?? "",
        fileName: input.filePath
      )

    case .write:
      // For Write, original is empty (new file or overwrite)
      return DiffInputData(
        oldContent: "",
        newContent: input.newString ?? "",
        fileName: input.filePath
      )

    case .multiEdit:
      // Combine all edits into a single diff
      var oldContent = ""
      var newContent = ""
      if let edits = input.edits {
        for (index, edit) in edits.enumerated() {
          if index > 0 {
            oldContent += "\n...\n"
            newContent += "\n...\n"
          }
          oldContent += edit["old_string"] ?? ""
          newContent += edit["new_string"] ?? ""
        }
      }
      return DiffInputData(
        oldContent: oldContent,
        newContent: newContent,
        fileName: input.filePath
      )
    }
  }
}

// MARK: - DiffInputData

/// Internal struct to hold diff data for rendering
private struct DiffInputData {
  let oldContent: String
  let newContent: String
  let fileName: String
}

// MARK: - DiffViewWithHeader

/// Wrapper that adds header controls to PierreDiffView without re-rendering issues
/// Replicates the exact UI from DiffEditsView's PierreDiffContentView
private struct DiffViewWithHeader: View {
  let oldContent: String
  let newContent: String
  let fileName: String
  @Binding var diffStyle: DiffStyle
  @Binding var overflowMode: OverflowMode

  @State private var webViewOpacity: Double = 1.0
  @State private var isWebViewReady = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with file info and controls
      headerView

      // Diff view with loading skeleton
      ZStack {
        PierreDiffView(
          oldContent: oldContent,
          newContent: newContent,
          fileName: fileName,
          diffStyle: $diffStyle,
          overflowMode: $overflowMode,
          onReady: {
            withAnimation(.easeInOut(duration: 0.3)) {
              isWebViewReady = true
            }
          }
        )
        .opacity(isWebViewReady ? webViewOpacity : 0)

        if !isWebViewReady {
          VStack(spacing: 12) {
            ProgressView()
              .controlSize(.small)
            Text("Loading diff...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.3), value: isWebViewReady)
    }
  }

  private var headerView: some View {
    VStack(alignment: .leading) {
      HStack {
        // File name with icon
        HStack {
          Image(systemName: "doc.text.fill")
            .foregroundStyle(.blue)
          Text(fileName)
            .font(.headline)
        }

        Spacer()

        HStack(spacing: 8) {
          // Split/Unified toggle button
          Button {
            toggleDiffStyle()
          } label: {
            Image(systemName: diffStyle == .split ? "rectangle.split.2x1" : "rectangle.stack")
              .font(.system(size: 14))
          }
          .buttonStyle(.plain)
          .help(diffStyle == .split ? "Switch to unified view" : "Switch to split view")

          // Wrap toggle button
          Button {
            toggleOverflowMode()
          } label: {
            Image(systemName: overflowMode == .wrap ? "text.alignleft" : "text.aligncenter")
              .font(.system(size: 14))
              .foregroundStyle(overflowMode == .wrap ? .primary : .secondary)
          }
          .buttonStyle(.plain)
          .help(overflowMode == .wrap ? "Disable word wrap" : "Enable word wrap")
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  // MARK: - Toggle Functions

  private func toggleDiffStyle() {
    Task {
      withAnimation(.easeOut(duration: 0.15)) {
        webViewOpacity = 0
      }
      try? await Task.sleep(for: .milliseconds(150))
      diffStyle = diffStyle == .split ? .unified : .split
      withAnimation(.easeIn(duration: 0.15)) {
        webViewOpacity = 1
      }
    }
  }

  private func toggleOverflowMode() {
    Task {
      withAnimation(.easeOut(duration: 0.15)) {
        webViewOpacity = 0
      }
      try? await Task.sleep(for: .milliseconds(150))
      overflowMode = overflowMode == .scroll ? .wrap : .scroll
      withAnimation(.easeIn(duration: 0.15)) {
        webViewOpacity = 1
      }
    }
  }
}

// MARK: - CodeChangeRow

private struct CodeChangeRow: View {
  let change: CodeChangeEntry
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        // Tool type icon
        Image(systemName: toolIcon)
          .font(.caption)
          .foregroundColor(toolColor)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 2) {
          // File name
          Text(change.fileName)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.medium)
            .lineLimit(1)

          // Timestamp
          Text(formatTime(change.timestamp))
            .font(.caption2)
            .foregroundColor(.secondary)
        }

        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isSelected ? Color.brandPrimary.opacity(0.15) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(isSelected ? Color.brandPrimary.opacity(0.3) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private var toolIcon: String {
    switch change.input.toolType {
    case .edit: return "pencil"
    case .write: return "doc.badge.plus"
    case .multiEdit: return "pencil.and.list.clipboard"
    }
  }

  private var toolColor: Color {
    switch change.input.toolType {
    case .edit: return .orange
    case .write: return .blue
    case .multiEdit: return .purple
    }
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - Preview

#Preview {
  CodeChangesView(
    session: CLISession(
      id: "test-session-id",
      projectPath: "/Users/test/project",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 10,
      isActive: true
    ),
    codeChangesState: CodeChangesState(changes: [
      CodeChangeEntry(
        id: UUID(),
        timestamp: Date().addingTimeInterval(-60),
        input: CodeChangeInput(
          toolType: .edit,
          filePath: "/Users/test/project/src/main.swift",
          oldString: "let x = 1",
          newString: "let x = 2"
        )
      ),
      CodeChangeEntry(
        id: UUID(),
        timestamp: Date().addingTimeInterval(-30),
        input: CodeChangeInput(
          toolType: .write,
          filePath: "/Users/test/project/src/new-file.swift",
          newString: "// New file content"
        )
      )
    ]),
    onDismiss: {}
  )
}
