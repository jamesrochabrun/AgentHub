//
//  FileExplorerView.swift
//  AgentHub
//
//  Full-screen file explorer with a tree sidebar and an editable code editor panel.
//  Mirrors the GitDiffView layout: header / sidebar / main panel.
//

import SwiftUI
import AppKit

/// A panel that lets the user browse and edit files in a project directory.
///
/// - Shows a hierarchical file tree in a collapsible sidebar (240 pt wide).
/// - Opens files in a source editor backed by CodeEditSourceEditor.
/// - Tracks unsaved changes and prompts before closing.
public struct FileExplorerView: View {

  // MARK: - Properties

  let session: CLISession
  let projectPath: String
  let onDismiss: () -> Void
  let isEmbedded: Bool
  let initialFilePath: String?

  // MARK: - State

  @State private var treeNodes: [FileTreeNode] = []
  @State private var isLoading = true
  @State private var selectedFilePath: String?
  @State private var fileContent: String = ""
  @State private var savedFileContent: String = ""
  @State private var isLoadingFile = false
  @State private var fileError: String?
  @State private var hasUnsavedChanges = false
  @State private var isSaving = false
  @State private var saveError: String?
  @State private var showSidebar = true
  @State private var showDiscardAlert = false
  @State private var expandedPaths: Set<String> = []
  @State private var loadingDirectories: Set<String> = []
  @State private var scrollToPath: String?
  @State private var hasLoadedTreeRoot = false
  @State private var editorDisplayMode: EditorDisplayMode = .highlighted
  @State private var editorDocumentID = UUID()

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  private var headerBackground: Color {
    Color.adaptiveExpandedContentBackground(for: colorScheme, theme: runtimeTheme)
  }


  // MARK: - Init

  public init(
    session: CLISession,
    projectPath: String,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false,
    initialFilePath: String? = nil
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.initialFilePath = initialFilePath
  }

  private var normalizedProjectPath: String {
    URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private var loadTaskID: String {
    normalizedProjectPath + "::" + (initialFilePath ?? "")
  }

  // MARK: - Body

  public var body: some View {
    VStack(spacing: 0) {
      if isLoading {
        VStack(spacing: 12) {
          ProgressView()
          Text("Loading files…")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(spacing: 0) {
          if showSidebar {
            ResizablePanelContainer(
              side: .leading,
              minWidth: 160,
              maxWidth: 480,
              defaultWidth: 240,
              userDefaultsKey: AgentHubDefaults.fileExplorerSidebarWidth
            ) {
              fileTreeSidebar
            }
          }
          VStack(spacing: 0) {
            contentAreaHeader
            Divider()
            fileContentArea
          }
          .blursWhileResizing()
        }
        .animation(.easeInOut(duration: 0.25), value: showSidebar)
      }
    }
    .frame(
      minWidth: isEmbedded ? 400 : nil,
      maxWidth: .infinity,
      minHeight: isEmbedded ? 400 : nil,
      maxHeight: .infinity
    )
    .task(id: loadTaskID) {
      await loadFileTree()
      if let initial = initialFilePath {
        let resolvedInitialPath = URL(fileURLWithPath: initial)
          .standardizedFileURL
          .resolvingSymlinksInPath()
          .path
        await expandToFile(initial)
        await openFile(at: initial)
        // Delay scroll to let the expanded tree render
        try? await Task.sleep(for: .milliseconds(100))
        scrollToPath = resolvedInitialPath
      }
    }
    .onKeyPress(.escape) {
      if hasUnsavedChanges {
        showDiscardAlert = true
        return .handled
      }
      onDismiss()
      return .handled
    }
    .confirmationDialog(
      "Unsaved Changes",
      isPresented: $showDiscardAlert,
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) {
        hasUnsavedChanges = false
        onDismiss()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("You have unsaved changes. Close anyway?")
    }
  }

  // MARK: - Content Area Header

  private var contentAreaHeader: some View {
    HStack(spacing: 8) {
      // Sidebar toggle (matches GitDiffView pattern)
      Button {
        showSidebar.toggle()
      } label: {
        Image(systemName: "sidebar.left")
          .font(.system(size: 14))
          .foregroundStyle(showSidebar ? .primary : .secondary)
      }
      .buttonStyle(.plain)
      .help(showSidebar ? "Hide file tree" : "Show file tree")

      // Divider
      Rectangle()
        .fill(Color.secondary.opacity(0.3))
        .frame(width: 1, height: 16)

      // File path breadcrumb or project name
      if let path = selectedFilePath {
        let relPath = path.hasPrefix(normalizedProjectPath + "/")
          ? String(path.dropFirst(normalizedProjectPath.count + 1))
          : (path as NSString).lastPathComponent
        HStack(spacing: 4) {
          Text(relPath)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let badgeLabel = editorDisplayMode.badgeLabel, fileError == nil {
            Text(badgeLabel)
              .font(.system(size: 10, weight: .medium))
              .foregroundColor(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(
                Capsule()
                  .fill(Color.secondary.opacity(0.12))
              )
          }
          if hasUnsavedChanges {
            Text("Modified")
              .font(.system(size: 10, weight: .medium))
              .foregroundColor(.orange)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(
                Capsule()
                  .fill(Color.orange.opacity(0.15))
              )
          }
        }
      } else {
        Text(URL(fileURLWithPath: projectPath).lastPathComponent)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)
      }

      Spacer()

      // Save error indicator
      if let saveError {
        Text(saveError)
          .font(.system(size: 10))
          .foregroundColor(.red)
          .lineLimit(1)
          .transition(.opacity)
      }

      // Save button
      if selectedFilePath != nil && hasUnsavedChanges {
        Button("Save") {
          saveCurrentFile()
        }
        .keyboardShortcut("s", modifiers: .command)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isSaving)
      }

      // Close button
      Button("Close") {
        if hasUnsavedChanges {
          showDiscardAlert = true
        } else {
          onDismiss()
        }
      }
      .controlSize(.small)
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .frame(height: AgentHubLayout.topBarHeight)
    .background(headerBackground)
  }

  // MARK: - File Tree Sidebar

  private var fileTreeSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Files")
          .font(.system(size: 13, weight: .bold, design: .monospaced))
        Spacer()
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: AgentHubLayout.topBarHeight)
      .background(headerBackground)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(treeNodes) { node in
              FileTreeNodeView(
                node: node,
                depth: 0,
                selectedFilePath: $selectedFilePath,
                expandedPaths: $expandedPaths,
                loadingPaths: loadingDirectories,
                onSelectFile: { path in
                  Task { await openFile(at: path) }
                },
                onToggleDirectory: { directory in
                  Task { await toggleDirectory(directory) }
                }
              )
            }
          }
          .padding(8)
        }
        .onChange(of: scrollToPath) { _, target in
          guard let target else { return }
          withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .center)
          }
          scrollToPath = nil
        }
      }
    }
  }

  // MARK: - File Content Area

  @ViewBuilder
  private var fileContentArea: some View {
    if let error = fileError {
      VStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 36))
          .foregroundColor(.red.opacity(0.6))
        Text("Cannot display file")
          .font(.headline)
          .foregroundColor(.secondary)
        Text(error)
          .font(.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding()
    } else if isLoadingFile {
      VStack(spacing: 12) {
        ProgressView()
        Text("Loading file…")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if selectedFilePath == nil {
      VStack(spacing: 12) {
        Image(systemName: "doc.text.magnifyingglass")
          .font(.system(size: 40))
          .foregroundColor(.secondary.opacity(0.6))
        Text("Select a file to view")
          .font(.callout)
          .foregroundColor(.secondary)
        Text("Browse the file tree or use \(Image(systemName: "command"))  P")
          .font(.caption)
          .foregroundColor(.secondary.opacity(0.6))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      SourceCodeEditorView(
        text: $fileContent,
        fileName: selectedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
        documentID: editorDocumentID,
        displayMode: editorDisplayMode,
        onTextChange: { updatedText in
          if updatedText != savedFileContent {
            hasUnsavedChanges = true
          }
        },
        onIdleTextSnapshot: { idleText in
          guard editorDisplayMode == .highlighted else { return }
          hasUnsavedChanges = idleText != savedFileContent
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Actions

  private func loadFileTree() async {
    isLoading = true
    loadingDirectories.removeAll()
    expandedPaths.removeAll()
    treeNodes = await FileIndexService.shared.rootNodes(projectPath: normalizedProjectPath)
    hasLoadedTreeRoot = true
    isLoading = false
  }

  private func openFile(at path: String) async {
    let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let binaryExts: Set<String> = [
      "png", "jpg", "jpeg", "gif", "pdf", "zip", "tar", "gz",
      "exe", "dylib", "a", "o", "mp3", "mp4", "mov", "woff", "ttf"
    ]

    selectedFilePath = resolvedPath
    fileError = nil
    saveError = nil
    isLoadingFile = false
    fileContent = ""
    savedFileContent = ""
    hasUnsavedChanges = false
    editorDisplayMode = .highlighted
    editorDocumentID = UUID()

    guard !binaryExts.contains(ext) else {
      fileError = "Binary files cannot be displayed."
      return
    }

    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: resolvedPath),
       let fileSize = attrs[.size] as? UInt64, fileSize > 10_000_000 {
      fileError = "File is too large to display (>10 MB)."
      return
    }

    isLoadingFile = true

    do {
      let content = try await FileIndexService.shared.readFile(at: resolvedPath, projectPath: normalizedProjectPath)
      fileContent = content
      savedFileContent = content
      hasUnsavedChanges = false
      editorDisplayMode = .displayMode(for: content)
      editorDocumentID = UUID()
      await FileIndexService.shared.addToRecent(resolvedPath)
    } catch {
      fileContent = ""
      savedFileContent = ""
      hasUnsavedChanges = false
      fileError = "Could not read file: \(error.localizedDescription)"
    }
    isLoadingFile = false
  }

  private func saveCurrentFile() {
    guard let path = selectedFilePath else { return }
    isSaving = true
    saveError = nil
    let content = fileContent
    Task {
      do {
        try await FileIndexService.shared.writeFile(at: path, content: content, projectPath: normalizedProjectPath)
        await MainActor.run {
          savedFileContent = content
          hasUnsavedChanges = false
          isSaving = false
        }
      } catch {
        await MainActor.run {
          saveError = "Save failed: \(error.localizedDescription)"
          isSaving = false
        }
      }
    }
  }

  private func toggleDirectory(_ directory: FileTreeNode) async {
    if expandedPaths.contains(directory.path) {
      expandedPaths.remove(directory.path)
      return
    }

    expandedPaths.insert(directory.path)
    guard directory.isDirectory,
          directory.children == nil,
          !loadingDirectories.contains(directory.path) else {
      return
    }

    await loadChildren(for: directory.path)
  }

  private func loadChildren(for directoryPath: String) async {
    guard !loadingDirectories.contains(directoryPath) else { return }
    loadingDirectories.insert(directoryPath)
    let children = await FileIndexService.shared.children(of: directoryPath, in: normalizedProjectPath)
    treeNodes = updatingChildren(
      in: treeNodes,
      for: directoryPath,
      children: children
    )
    loadingDirectories.remove(directoryPath)
  }

  private func expandToFile(_ filePath: String) async {
    let resolvedPath = URL(fileURLWithPath: filePath).standardizedFileURL.resolvingSymlinksInPath().path
    let relative = resolvedPath.replacingOccurrences(of: normalizedProjectPath + "/", with: "")
    let parts = relative.components(separatedBy: "/")
    var accumulated = normalizedProjectPath
    for part in parts.dropLast() {
      accumulated += "/" + part
      expandedPaths.insert(accumulated)
      await ensureDirectoryLoaded(accumulated)
    }
  }

  private func ensureDirectoryLoaded(_ directoryPath: String) async {
    if directoryPath == normalizedProjectPath {
      if !hasLoadedTreeRoot {
        await loadFileTree()
      }
      return
    }

    guard let node = findNode(at: directoryPath, in: treeNodes), node.children == nil else {
      return
    }
    await loadChildren(for: directoryPath)
  }

  private func findNode(at path: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
    for node in nodes {
      if node.path == path {
        return node
      }
      if let children = node.children, let found = findNode(at: path, in: children) {
        return found
      }
    }
    return nil
  }

  private func updatingChildren(
    in nodes: [FileTreeNode],
    for targetPath: String,
    children: [FileTreeNode]
  ) -> [FileTreeNode] {
    nodes.map { node in
      var updated = node
      if node.path == targetPath {
        updated.children = children
        return updated
      }
      if let existingChildren = node.children {
        updated.children = updatingChildren(
          in: existingChildren,
          for: targetPath,
          children: children
        )
      }
      return updated
    }
  }
}

// MARK: - FileTreeNodeView

/// Recursive view that renders a single ``FileTreeNode`` and, when expanded, its children.
private struct FileTreeNodeView: View {
  let node: FileTreeNode
  let depth: Int
  @Binding var selectedFilePath: String?
  @Binding var expandedPaths: Set<String>
  let loadingPaths: Set<String>
  let onSelectFile: (String) -> Void
  let onToggleDirectory: (FileTreeNode) -> Void

  @State private var isHovered = false

  private var isExpanded: Bool {
    expandedPaths.contains(node.path)
  }

  private var isSelected: Bool {
    !node.isDirectory && selectedFilePath == node.path
  }

  private var rowBackground: Color {
    if isSelected { return Color.accentColor }
    if isHovered { return Color.primary.opacity(0.08) }
    return Color.clear
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: handleTap) {
        HStack(spacing: 4) {
          // Indentation
          if depth > 0 {
            Spacer()
              .frame(width: CGFloat(depth) * 12)
          }

          // Chevron (directories only) or spacer
          if node.isDirectory {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2)
              .foregroundColor(.secondary)
              .frame(width: 12)
          } else {
            Spacer()
              .frame(width: 12)
          }

          // Icon
          Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
            .font(.caption)
            .foregroundColor(node.isDirectory ? .accentColor.opacity(0.7) : fileIconColor(for: node.name))
            .frame(width: 16)

          // Name
          Text(node.name)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(node.isDirectory ? .medium : .regular)
            .lineLimit(1)
            .foregroundColor(isSelected ? .white : .primary)

          Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(rowBackground)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { isHovered = $0 }
      .id(node.path)

      // Children
      if node.isDirectory && isExpanded {
        if loadingPaths.contains(node.path) {
          HStack(spacing: 8) {
            Spacer()
              .frame(width: CGFloat(depth + 1) * 12 + 28)
            ProgressView()
              .controlSize(.small)
            Text("Loading…")
              .font(.system(size: 11))
              .foregroundColor(.secondary)
          }
          .padding(.vertical, 4)
        } else if let children = node.children {
          ForEach(children) { child in
            FileTreeNodeView(
              node: child,
              depth: depth + 1,
              selectedFilePath: $selectedFilePath,
              expandedPaths: $expandedPaths,
              loadingPaths: loadingPaths,
              onSelectFile: onSelectFile,
              onToggleDirectory: onToggleDirectory
            )
          }
        }
      }
    }
  }

  private func handleTap() {
    if node.isDirectory {
      onToggleDirectory(node)
    } else {
      onSelectFile(node.path)
    }
  }

  private func fileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":              return "swift"
    case "js", "ts", "jsx", "tsx": return "chevron.left.forwardslash.chevron.right"
    case "json":               return "curlybraces"
    case "md", "markdown":     return "doc.richtext"
    case "html", "htm":        return "globe"
    case "css", "scss", "sass": return "paintbrush"
    case "sh", "bash", "zsh":  return "terminal"
    case "yaml", "yml":        return "list.bullet.indent"
    case "xml":                return "chevron.left.forwardslash.chevron.right"
    case "py":                 return "chevron.left.forwardslash.chevron.right"
    case "rb":                 return "diamond"
    case "go":                 return "chevron.left.forwardslash.chevron.right"
    case "rs":                 return "chevron.left.forwardslash.chevron.right"
    default:                   return "doc.text"
    }
  }

  private func fileIconColor(for name: String) -> Color {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":              return .orange
    case "js", "jsx":          return .yellow
    case "ts", "tsx":          return .blue
    case "json":               return .green
    case "md", "markdown":     return .secondary
    case "html", "htm":        return .orange
    case "css", "scss", "sass": return .purple
    case "sh", "bash", "zsh":  return .green
    case "yaml", "yml":        return .mint
    case "py":                 return .blue
    case "rb":                 return .red
    case "go":                 return .teal
    case "rs":                 return .orange
    default:                   return .secondary
    }
  }
}

// MARK: - Preview

#Preview {
  FileExplorerView(
    session: CLISession(
      id: "preview-session",
      projectPath: "/Users/developer/Developing/AgentHub",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 0,
      isActive: false
    ),
    projectPath: "/Users/developer/Developing/AgentHub",
    onDismiss: {}
  )
}
