//
//  FileExplorerView.swift
//  AgentHub
//
//  Full-screen file explorer with a tree sidebar and an editable code editor panel.
//  Mirrors the GitDiffView layout: header / sidebar / main panel.
//

import SwiftUI
import AppKit
import CodeEditTextView
import HighlightSwift

// MARK: - FileExplorerView

enum EditorDisplayMode: Equatable {
  case highlighted
  case plainText

  var badgeLabel: String? {
    switch self {
    case .highlighted:
      nil
    case .plainText:
      "Fast Mode"
    }
  }

  var highlightsSyntax: Bool {
    self == .highlighted
  }
}

/// A panel that lets the user browse and edit files in a project directory.
///
/// - Shows a hierarchical file tree in a collapsible sidebar (240 pt wide).
/// - Opens files in a ``CETextViewRepresentable`` editor backed by ``CodeEditTextView/TextView``.
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

  // Find bar
  @State private var showFindBar = false
  @State private var findQuery = ""
  @State private var findMatchRanges: [NSRange] = []
  @State private var findCurrentIndex = 0
  @State private var findCaseSensitive = false
  @State private var coordinatorRef = CoordinatorRef()
  @State private var findDebounceTask: Task<Void, Never>?


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
      if showFindBar {
        dismissFindBar()
        return .handled
      }
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
      Button {
        if hasUnsavedChanges {
          showDiscardAlert = true
        } else {
          onDismiss()
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.surfaceElevated)
  }

  // MARK: - File Tree Sidebar

  private var fileTreeSidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Files")
          .font(.system(size: 13, weight: .bold, design: .monospaced))
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

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
      VStack(spacing: 0) {
        if showFindBar {
          FindBarView(
            query: $findQuery,
            currentIndex: findCurrentIndex,
            totalMatches: findMatchRanges.count,
            caseSensitive: $findCaseSensitive,
            onNext: { navigateFind(delta: 1) },
            onPrevious: { navigateFind(delta: -1) },
            onDismiss: { dismissFindBar() },
            onQueryChanged: { debouncedFind() },
            onCaseSensitiveChanged: { performFind() }
          )
          Divider()
        }
        CETextViewRepresentable(
          text: $fileContent,
          fileName: selectedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
          documentID: editorDocumentID,
          displayMode: editorDisplayMode,
          coordinatorRef: coordinatorRef,
          onTextChange: { updatedText in
            if updatedText != savedFileContent {
              hasUnsavedChanges = true
            }
          },
          onIdleTextSnapshot: { idleText in
            guard editorDisplayMode == .highlighted else { return }
            hasUnsavedChanges = idleText != savedFileContent
          },
          onTextEditedWhileSearching: showFindBar ? { performFind() } : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background {
        // Hidden button to capture Cmd+F
        Button("") { toggleFindBar() }
          .keyboardShortcut("f", modifiers: .command)
          .opacity(0)
          .frame(width: 0, height: 0)
      }
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

  // MARK: - Find Bar Actions

  private func toggleFindBar() {
    if showFindBar {
      dismissFindBar()
    } else {
      showFindBar = true
    }
  }

  private func dismissFindBar() {
    showFindBar = false
    findQuery = ""
    findMatchRanges = []
    findCurrentIndex = 0
    coordinatorRef.coordinator?.clearSearchHighlights()
  }

  private func debouncedFind() {
    findDebounceTask?.cancel()
    findDebounceTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      performFind()
    }
  }

  private func performFind() {
    guard let coordinator = coordinatorRef.coordinator else { return }
    let ranges = coordinator.performSearch(query: findQuery, caseSensitive: findCaseSensitive)
    findMatchRanges = ranges
    if ranges.isEmpty {
      findCurrentIndex = 0
    } else {
      findCurrentIndex = 1
      coordinator.navigateToMatch(at: 0, allRanges: ranges)
    }
  }

  private func navigateFind(delta: Int) {
    guard !findMatchRanges.isEmpty, let coordinator = coordinatorRef.coordinator else { return }
    let count = findMatchRanges.count
    // findCurrentIndex is 1-based for display
    let zeroBasedIndex = findCurrentIndex - 1
    let newIndex = ((zeroBasedIndex + delta) % count + count) % count
    findCurrentIndex = newIndex + 1
    coordinator.navigateToMatch(at: newIndex, allRanges: findMatchRanges)
  }

  private func openFile(at path: String) async {
    let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let binaryExts: Set<String> = [
      "png", "jpg", "jpeg", "gif", "pdf", "zip", "tar", "gz",
      "exe", "dylib", "a", "o", "mp3", "mp4", "mov", "woff", "ttf"
    ]
    // Reset find bar on file switch
    showFindBar = false
    findQuery = ""
    findMatchRanges = []
    findCurrentIndex = 0

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

    // Guard against loading very large files that would exhaust memory
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
      editorDisplayMode = Self.displayMode(for: content)
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

  private static func displayMode(for content: String) -> EditorDisplayMode {
    let byteCount = content.utf8.count
    let lineCount = Self.lineCount(for: content)
    if byteCount <= 300_000 && lineCount <= 5_000 {
      return .highlighted
    }
    return .plainText
  }

  private static func lineCount(for content: String) -> Int {
    guard !content.isEmpty else { return 0 }
    return content.utf8.reduce(into: 1) { count, byte in
      if byte == 0x0A {
        count += 1
      }
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

// MARK: - CoordinatorRef

/// Simple reference holder so FileExplorerView can call Coordinator methods from SwiftUI callbacks.
final class CoordinatorRef {
  weak var coordinator: CETextViewRepresentable.Coordinator?
}

// MARK: - FindBarView

/// Compact find bar matching Xcode style: [TextField] [matchCount] [< prev] [> next] [Aa] [X close]
private struct FindBarView: View {
  @Binding var query: String
  let currentIndex: Int
  let totalMatches: Int
  @Binding var caseSensitive: Bool
  let onNext: () -> Void
  let onPrevious: () -> Void
  let onDismiss: () -> Void
  let onQueryChanged: () -> Void
  let onCaseSensitiveChanged: () -> Void

  @FocusState private var isFieldFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
        TextField("Find…", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 12, design: .monospaced))
          .focused($isFieldFocused)
          .onSubmit { onNext() }
          .onChange(of: query) { _, _ in
            onQueryChanged()
          }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.primary.opacity(0.06))
      )
      .frame(minWidth: 140, maxWidth: 260)

      // Match count
      if !query.isEmpty {
        Text(totalMatches == 0 ? "No results" : "\(currentIndex) of \(totalMatches)")
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(totalMatches == 0 ? .red.opacity(0.8) : .secondary)
          .frame(minWidth: 60)
      }

      // Previous / Next
      Button(action: onPrevious) {
        Image(systemName: "chevron.up")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .disabled(totalMatches == 0)
      .help("Previous match (Shift+Enter)")

      Button(action: onNext) {
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .disabled(totalMatches == 0)
      .help("Next match (Enter)")

      // Case sensitivity toggle
      Button {
        caseSensitive.toggle()
        onCaseSensitiveChanged()
      } label: {
        Text("Aa")
          .font(.system(size: 11, weight: caseSensitive ? .bold : .regular))
          .foregroundColor(caseSensitive ? .accentColor : .secondary)
          .frame(width: 22, height: 22)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(caseSensitive ? Color.accentColor.opacity(0.15) : Color.clear)
          )
      }
      .buttonStyle(.plain)
      .help("Match case")

      Spacer()

      // Close
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Close find bar (Esc)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.surfaceElevated)
    .onAppear { isFieldFocused = true }
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
    .onKeyPress(.return, phases: .down) { event in
      if event.modifiers.contains(.shift) {
        onPrevious()
        return .handled
      }
      return .ignored
    }
  }
}

// MARK: - CETextViewRepresentable

/// SwiftUI wrapper around ``CodeEditTextView/TextView`` with syntax highlighting via HighlightSwift.
public struct CETextViewRepresentable: NSViewRepresentable {

  @Binding var text: String
  let fileName: String
  let documentID: UUID
  let displayMode: EditorDisplayMode
  var coordinatorRef: CoordinatorRef?
  let onTextChange: (String) -> Void
  let onIdleTextSnapshot: (String) -> Void
  var onTextEditedWhileSearching: (() -> Void)?
  @Environment(\.colorScheme) private var colorScheme

  public func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  public func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.contentView.postsFrameChangedNotifications = true
    scrollView.contentView.postsBoundsChangedNotifications = true

    let textView = TextView(
      string: text,
      font: .monospacedSystemFont(ofSize: 12, weight: .regular),
      textColor: .labelColor,
      lineHeightMultiplier: 1.3,
      wrapLines: false,
      isEditable: true,
      isSelectable: true,
      letterSpacing: 1.0,
      useSystemCursor: true,
      delegate: context.coordinator
    )
    textView.edgeInsets = HorizontalEdgeInsets(left: 8, right: 8)

    scrollView.documentView = textView
    textView.updateFrameIfNeeded()
    context.coordinator.textView = textView
    coordinatorRef?.coordinator = context.coordinator
    context.coordinator.loadDocument(
      text: text,
      fileName: fileName,
      documentID: documentID,
      displayMode: displayMode,
      colorScheme: colorScheme
    )
    return scrollView
  }

  public func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard context.coordinator.textView != nil else { return }

    if context.coordinator.currentDocumentID != documentID {
      context.coordinator.loadDocument(
        text: text,
        fileName: fileName,
        documentID: documentID,
        displayMode: displayMode,
        colorScheme: colorScheme
      )
      return
    }

    if context.coordinator.currentDisplayMode != displayMode {
      context.coordinator.currentDisplayMode = displayMode
      if displayMode.highlightsSyntax {
        context.coordinator.applySyntaxHighlighting(
          text: text,
          fileName: fileName,
          colorScheme: colorScheme
        )
      } else {
        context.coordinator.applyPlainTextAppearance()
      }
    }

    if context.coordinator.lastColorScheme != colorScheme {
      context.coordinator.lastColorScheme = colorScheme
      if displayMode.highlightsSyntax {
        context.coordinator.applySyntaxHighlighting(
          text: text,
          fileName: fileName,
          colorScheme: colorScheme
        )
      } else {
        context.coordinator.applyPlainTextAppearance()
      }
    }
  }

  // MARK: - Coordinator

  public class Coordinator: NSObject, TextViewDelegate {
    var parent: CETextViewRepresentable
    weak var textView: TextView?
    var isUpdatingFromBinding = false
    var currentDocumentID: UUID?
    var currentDisplayMode: EditorDisplayMode = .highlighted
    var lastColorScheme: ColorScheme?
    private var highlightTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private let highlighter = Highlight()

    init(parent: CETextViewRepresentable) {
      self.parent = parent
    }

    func loadDocument(
      text: String,
      fileName: String,
      documentID: UUID,
      displayMode: EditorDisplayMode,
      colorScheme: ColorScheme
    ) {
      guard let textView else { return }
      highlightTask?.cancel()
      idleTask?.cancel()
      currentDocumentID = documentID
      currentDisplayMode = displayMode
      lastColorScheme = colorScheme

      isUpdatingFromBinding = true
      textView.string = text
      textView.textColor = .labelColor
      textView.wrapLines = false
      textView.updateFrameIfNeeded()
      isUpdatingFromBinding = false

      if displayMode.highlightsSyntax {
        applySyntaxHighlighting(text: text, fileName: fileName, colorScheme: colorScheme)
      } else {
        applyPlainTextAppearance()
      }
    }

    public func textView(
      _ textView: TextView,
      didReplaceContentsIn range: NSRange,
      with string: String
    ) {
      guard !isUpdatingFromBinding else { return }
      let newText = textView.string
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.parent.text = newText
        self.parent.onTextChange(newText)
      }
      schedulePostEditWork(text: newText)
      // Re-run search if find bar is active
      if let callback = parent.onTextEditedWhileSearching {
        scheduleSearchRefresh(callback: callback)
      }
    }

    func applySyntaxHighlighting(text: String, fileName: String, colorScheme: ColorScheme) {
      highlightTask?.cancel()
      guard currentDisplayMode.highlightsSyntax else {
        applyPlainTextAppearance()
        return
      }
      guard !text.isEmpty else { return }

      let lang = Self.languageForFile(fileName)
      let colors: HighlightColors = colorScheme == .dark ? .dark(.github) : .light(.github)

      highlightTask = Task { [weak self, highlighter] in
        guard let self else { return }
        do {
          let attributed: AttributedString
          if let lang {
            attributed = try await highlighter.attributedText(text, language: lang, colors: colors)
          } else {
            attributed = try await highlighter.attributedText(text, colors: colors)
          }
          guard !Task.isCancelled else { return }

          // HighlightSwift trims whitespace/newlines, so calculate the leading offset
          let leadingWS = text.prefix(while: { $0.isWhitespace || $0.isNewline })
          let leadingOffset = (leadingWS as Substring).utf16.count

          // Extract color ranges from the AttributedString
          let nsHighlighted = NSAttributedString(attributed)
          var colorRanges: [(NSRange, NSColor)] = []
          nsHighlighted.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: nsHighlighted.length),
            options: []
          ) { value, range, _ in
            if let color = value as? NSColor {
              colorRanges.append((range, color))
            }
          }

          guard !Task.isCancelled, !colorRanges.isEmpty else { return }
          await MainActor.run { [weak self] in
            self?.applyHighlightColors(colorRanges, leadingOffset: leadingOffset)
          }
        } catch {
          // Silently fail — file displays without highlighting
        }
      }
    }

    private func schedulePostEditWork(text: String) {
      idleTask?.cancel()
      let fileName = parent.fileName
      let colorScheme = lastColorScheme ?? .light
      let displayMode = currentDisplayMode
      idleTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled else { return }
        await MainActor.run { [weak self] in
          self?.parent.onIdleTextSnapshot(text)
        }
        guard !Task.isCancelled, displayMode.highlightsSyntax else { return }
        self?.applySyntaxHighlighting(text: text, fileName: fileName, colorScheme: colorScheme)
      }
    }

    private func applyHighlightColors(_ colorRanges: [(NSRange, NSColor)], leadingOffset: Int) {
      guard let textView, let storage = textView.textStorage else { return }
      let storageLen = storage.length
      guard storageLen > 0 else { return }

      storage.beginEditing()
      let fullRange = NSRange(location: 0, length: storageLen)
      storage.removeAttribute(.foregroundColor, range: fullRange)
      storage.addAttribute(.foregroundColor, value: textView.textColor, range: fullRange)
      for (range, color) in colorRanges {
        let adjusted = NSRange(location: range.location + leadingOffset, length: range.length)
        if adjusted.location >= 0, adjusted.location + adjusted.length <= storageLen {
          storage.addAttribute(.foregroundColor, value: color, range: adjusted)
        }
      }
      storage.endEditing()

      // Force CodeEditTextView to re-layout with new attributes
      textView.layoutManager?.setNeedsLayout()
      textView.needsLayout = true
      textView.needsDisplay = true
    }

    func applyPlainTextAppearance() {
      highlightTask?.cancel()
      guard let textView, let storage = textView.textStorage else { return }
      let storageLen = storage.length
      guard storageLen > 0 else { return }

      let fullRange = NSRange(location: 0, length: storageLen)
      storage.beginEditing()
      storage.removeAttribute(.foregroundColor, range: fullRange)
      storage.addAttribute(.foregroundColor, value: textView.textColor, range: fullRange)
      storage.endEditing()
      textView.layoutManager?.setNeedsLayout()
      textView.needsLayout = true
      textView.needsDisplay = true
    }

    // MARK: - Find / Search

    private static let findGroupID = "find"
    /// Cap rendered emphasis layers to avoid performance issues on large files.
    private static let maxRenderedEmphases = 500
    private var searchDebounceTask: Task<Void, Never>?
    private var lastActiveIndex: Int = 0

    /// Searches the text view content for all occurrences of `query`.
    /// Returns the collected `NSRange` array and updates emphasis highlights.
    @discardableResult
    func performSearch(query: String, caseSensitive: Bool) -> [NSRange] {
      guard let textView, !query.isEmpty else {
        clearSearchHighlights()
        return []
      }

      let nsString = textView.string as NSString
      let textLength = nsString.length
      guard textLength > 0 else { return [] }

      let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
      var searchRange = NSRange(location: 0, length: textLength)
      var ranges: [NSRange] = []

      while searchRange.location < textLength {
        let foundRange = nsString.range(of: query, options: options, range: searchRange)
        guard foundRange.location != NSNotFound else { break }
        ranges.append(foundRange)
        searchRange.location = foundRange.location + foundRange.length
        searchRange.length = textLength - searchRange.location
      }

      guard !ranges.isEmpty else {
        clearSearchHighlights()
        return []
      }

      // Build emphases — cap rendered layers for performance, but report all matches
      let renderCount = min(ranges.count, Self.maxRenderedEmphases)
      let emphases = (0..<renderCount).map { idx in
        Emphasis(range: ranges[idx], style: .standard, inactive: idx != 0)
      }
      textView.emphasisManager?.replaceEmphases(emphases, for: Self.findGroupID)

      // Scroll to first match
      textView.scrollToRange(ranges[0], center: true)

      return ranges
    }

    /// Navigates to match at `index`, updating only the two changed emphases (old active → inactive,
    /// new active → active) instead of rebuilding all layers.
    func navigateToMatch(at index: Int, allRanges: [NSRange]) {
      guard let textView, !allRanges.isEmpty else { return }
      let renderCount = min(allRanges.count, Self.maxRenderedEmphases)
      let previousIndex = lastActiveIndex
      lastActiveIndex = index

      // If both indices are within rendered range, do a surgical update
      if previousIndex < renderCount, index < renderCount {
        textView.emphasisManager?.updateEmphases(for: Self.findGroupID) { existing in
          var updated = existing
          // Deactivate old match
          if previousIndex < updated.count {
            let old = updated[previousIndex]
            updated[previousIndex] = Emphasis(
              range: old.range, style: .standard, inactive: true
            )
          }
          // Activate new match
          if index < updated.count {
            let current = updated[index]
            updated[index] = Emphasis(
              range: current.range, style: .standard, inactive: false
            )
          }
          return updated
        }
      } else {
        // Fallback: full rebuild when navigating beyond rendered range
        let emphases = (0..<renderCount).map { idx in
          Emphasis(range: allRanges[idx], style: .standard, inactive: idx != index)
        }
        textView.emphasisManager?.replaceEmphases(emphases, for: Self.findGroupID)
      }
      textView.scrollToRange(allRanges[index], center: true)
    }

    /// Clears all find-related emphasis highlights.
    func clearSearchHighlights() {
      textView?.emphasisManager?.removeEmphases(for: Self.findGroupID)
    }

    /// Called when text is edited while find bar is visible — debounces re-search.
    func scheduleSearchRefresh(callback: @escaping () -> Void) {
      searchDebounceTask?.cancel()
      searchDebounceTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        callback()
      }
    }

    static func languageForFile(_ name: String) -> HighlightLanguage? {
      let ext = (name as NSString).pathExtension.lowercased()
      switch ext {
      case "swift":                    return .swift
      case "js", "jsx":                return .javaScript
      case "ts", "tsx":                return .typeScript
      case "py":                       return .python
      case "rb":                       return .ruby
      case "go":                       return .go
      case "rs":                       return .rust
      case "java":                     return .java
      case "kt":                       return .kotlin
      case "c", "h":                   return .c
      case "cpp", "cxx", "cc", "hpp":  return .cPlusPlus
      case "cs":                       return .cSharp
      case "php":                      return .php
      case "html", "htm":              return .html
      case "css":                      return .css
      case "scss":                     return .scss
      case "json":                     return .json
      case "yaml", "yml":              return .yaml
      case "toml":                     return .toml
      case "xml":                      return .html
      case "sql":                      return .sql
      case "sh", "bash", "zsh":        return .bash
      case "md", "markdown":           return .markdown
      case "dockerfile":               return .dockerfile
      case "makefile":                 return .makefile
      case "lua":                      return .lua
      case "r":                        return .r
      case "dart":                     return .dart
      case "scala":                    return .scala
      case "diff", "patch":            return .diff
      default:                         return nil
      }
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
