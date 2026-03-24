//
//  WebPreviewView.swift
//  AgentHub
//
//  Smart web preview that detects the project type and chooses the optimal
//  rendering strategy: instant file:// loading for static HTML, or dev server
//  for framework projects requiring transpilation.
//

import ClaudeCodeSDK
import SwiftUI
import Canvas

private enum WebPreviewInspectBehavior: String, CaseIterable, Identifiable {
  case input
  case context
  case edit

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .input: return "square.and.pencil"
    case .context: return "square.and.arrow.up"
    case .edit: return "slider.horizontal.3"
    }
  }

  var helpText: String {
    switch self {
    case .input:
      return "Select an element, then type an instruction before sending it to the agent."
    case .context:
      return "Queue selected elements in the preview to attach them to the next terminal message."
    case .edit:
      return "Select an element and edit its backing source file without sending anything to the terminal."
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .input: return "Instruction mode"
    case .context: return "Queued context mode"
    case .edit: return "Source edit mode"
    }
  }

  var modeName: String {
    switch self {
    case .input: return "inspect"
    case .context: return "context"
    case .edit: return "edit"
    }
  }

  var canvasMode: InspectMode {
    switch self {
    case .input: return .input
    case .context: return .context
    case .edit: return .input
    }
  }
}

// MARK: - WebPreviewView

/// Displays a web preview with smart resolution: loads static HTML files instantly
/// via `file://` URLs, or starts a dev server for framework projects.
///
/// When the agent's session has a detected localhost URL, the preview connects
/// to that URL directly (no server spawned). The URL is observed reactively —
/// if the agent switches ports, the preview follows automatically.
public struct WebPreviewView: View {
  let session: CLISession
  let projectPath: String
  let onDismiss: () -> Void
  var isEmbedded: Bool = false
  var onInspectSubmit: ((String, CLISession) -> Void)?
  let viewModel: CLISessionsViewModel?
  /// Reactive localhost URL from the agent's session. When this changes, the preview updates.
  var agentLocalhostURL: URL?
  var monitorState: SessionMonitorState?

  @State private var isLoading: Bool = false
  @State private var currentURL: URL?
  @State private var resolution: WebPreviewResolution?
  @State private var selectedFilePath: String?
  @State private var webRenderableFiles: [GitDiffFileEntry] = []
  @State private var fileWatcher = WebPreviewFileWatcher()
  @State private var inspectState = ElementInspectState()
  @State private var inspectBehavior: WebPreviewInspectBehavior = .input
  @State private var localContextQueue = WebPreviewContextQueue()
  @State private var hasLoadedExternalContent = false
  @State private var localhostReloadToken: UUID?
  @State private var handledCodeChangeActivityID: UUID?
  @State private var localhostPreviewStartedAt = Date()
  @State private var localhostReloadTask: Task<Void, Never>?
  @State private var inspectorViewModel: WebPreviewInspectorViewModel

  /// Uses session ID as key for DevServerManager to support multiple sessions
  private var serverKey: String { session.id }

  private var serverState: DevServerState {
    DevServerManager.shared.state(for: serverKey)
  }

  private var isExternalServer: Bool {
    DevServerManager.shared.isExternalServer(for: serverKey)
  }

  public init(
    session: CLISession,
    projectPath: String,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false,
    onInspectSubmit: ((String, CLISession) -> Void)? = nil,
    viewModel: CLISessionsViewModel? = nil,
    agentLocalhostURL: URL? = nil,
    monitorState: SessionMonitorState? = nil
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.onInspectSubmit = onInspectSubmit
    self.viewModel = viewModel
    self.agentLocalhostURL = agentLocalhostURL
    self.monitorState = monitorState
    self._inspectorViewModel = State(
      initialValue: WebPreviewInspectorViewModel(
        sessionID: session.id,
        projectPath: projectPath
      )
    )
  }

  private var latestLocalhostReloadSignal: WebPreviewLocalhostReloadSignal? {
    WebPreviewLocalhostReloadSignal.latest(from: monitorState)
  }

  private var queuedContext: WebPreviewContextQueue {
    viewModel?.queuedWebPreviewContextStore.queue(for: session.id) ?? localContextQueue
  }

  private var showsInspectorRail: Bool {
    inspectBehavior == .edit && inspectorViewModel.isPanelVisible
  }

  public var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      content
    }
    .frame(
      minWidth: isEmbedded ? 400 : 800, idealWidth: isEmbedded ? .infinity : 1000, maxWidth: .infinity,
      minHeight: isEmbedded ? 400 : 600, idealHeight: isEmbedded ? .infinity : 800, maxHeight: .infinity
    )
    .task {
      await loadPreview()
    }
    .onChange(of: agentLocalhostURL) { _, newURL in
      guard let newURL else { return }
      Task {
        await connectToAgentServer(newURL, logChange: true)
      }
    }
    .onChange(of: latestLocalhostReloadSignal) { _, newSignal in
      handleLocalhostReloadSignal(newSignal)
    }
    .onChange(of: inspectBehavior) { _, newBehavior in
      guard inspectState.isActive else { return }
      inspectState.activate(mode: newBehavior.canvasMode)
      Task {
        await inspectorViewModel.flushPendingWriteIfNeeded()
        if newBehavior != .edit {
          await inspectorViewModel.closePanel()
        }
      }
    }
    .onChange(of: selectedFilePath) { _, newPath in
      if let path = newPath {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        fileWatcher.watch(directory: dir)
      } else {
        fileWatcher.stop()
      }
    }
    .onKeyPress(.escape) {
      if inspectState.isActive {
        deactivateInspector()
        return .handled
      }
      onDismiss()
      return .handled
    }
    .onDisappear {
      deactivateInspector()
      Task {
        await inspectorViewModel.flushPendingWriteIfNeeded()
      }
      localhostReloadTask?.cancel()
      fileWatcher.stop()
      if case .devServer = resolution {
        DevServerManager.shared.stopServer(for: serverKey)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      // Center: status/file info based on resolution
      centerIndicator

      Spacer()

      // Controls
      headerControls
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(Color.surfaceElevated)
  }

  // MARK: - Center Indicator

  @ViewBuilder
  private var centerIndicator: some View {
    switch resolution {
    case .directFile:
      directFileIndicator
    case .devServer:
      devServerStatusIndicator
    case .noContent:
      EmptyView()
    case nil:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Detecting project...").font(.caption).foregroundColor(.secondary)
      }
    }
  }

  @ViewBuilder
  private var directFileIndicator: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color.green)
        .frame(width: 6, height: 6)

      if webRenderableFiles.count > 1 {
        Picker(selection: $selectedFilePath) {
          ForEach(webRenderableFiles) { file in
            Text(file.fileName)
              .tag(Optional(file.filePath))
          }
        } label: {
          EmptyView()
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 200)
      } else if let path = selectedFilePath {
        Text(URL(fileURLWithPath: path).lastPathComponent)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)
      }
    }
  }

  @ViewBuilder
  private var devServerStatusIndicator: some View {
    switch serverState {
    case .idle:
      EmptyView()
    case .detecting:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Detecting project...").font(.caption).foregroundColor(.secondary)
      }
    case .starting(let message):
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text(message).font(.caption).foregroundColor(.secondary)
      }
    case .waitingForReady:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Starting server...").font(.caption).foregroundColor(.secondary)
      }
    case .ready(let url):
      HStack(spacing: 6) {
        Circle()
          .fill(Color.green)
          .frame(width: 6, height: 6)
        Text(url.absoluteString)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)
      }
    case .failed:
      HStack(spacing: 6) {
        Circle()
          .fill(Color.red)
          .frame(width: 6, height: 6)
        Text("Failed")
          .font(.caption)
          .foregroundColor(.red)
      }
    case .stopping:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Stopping...").font(.caption).foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Header Controls

  @ViewBuilder
  private var headerControls: some View {
    HStack(spacing: 12) {
      switch resolution {
      case .directFile:
        // Reload button for file:// preview
        Button(action: {
          fileWatcher.reloadToken = UUID()
        }) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .help("Reload file")

      case .devServer:
        // Only show server control buttons for servers we manage (not the agent's)
        if !isExternalServer {
          if case .ready = serverState {
            Button(action: {
              DevServerManager.shared.stopServer(for: serverKey)
              Task { await DevServerManager.shared.startServer(for: serverKey, projectPath: projectPath) }
            }) {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Restart server")

            Button(action: {
              DevServerManager.shared.stopServer(for: serverKey)
            }) {
              Image(systemName: "stop.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop server")
          }

          if case .failed = serverState {
            Button(action: {
              Task { await DevServerManager.shared.startServer(for: serverKey, projectPath: projectPath) }
            }) {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Retry")
          }
        }

      default:
        EmptyView()
      }

      if inspectState.isActive {
        HStack(spacing: 6) {
          ForEach(WebPreviewInspectBehavior.allCases) { behavior in
            Button {
              inspectBehavior = behavior
            } label: {
              Image(systemName: behavior.icon)
                .font(.caption)
                .frame(width: 26, height: 20)
                .foregroundColor(inspectBehavior == behavior ? .accentColor : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(behavior.accessibilityLabel)
            .help(behavior.helpText)
          }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }

      // Inspect toggle
      Button {
        toggleInspector()
      } label: {
        Image(systemName: "cursorarrow.click.2")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(inspectState.isActive ? .accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .help("\(inspectState.isActive ? "Stop" : "Start") \(inspectBehavior.modeName) mode (Cmd+Shift+I)")

      // Hidden keyboard shortcut
      Button("") {
        toggleInspector()
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .hidden()
      .frame(width: 0, height: 0)

      Button("Close") {
        onDismiss()
      }
    }
    .animation(.easeInOut(duration: 0.2), value: inspectBehavior)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    HStack(spacing: 0) {
      previewContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if showsInspectorRail {
        ResizablePanelContainer(
          side: .trailing,
          minWidth: 320,
          maxWidth: 680,
          defaultWidth: 360,
          userDefaultsKey: AgentHubDefaults.webPreviewInspectorWidth
        ) {
          WebPreviewInspectorRail(
            viewModel: inspectorViewModel,
            onClose: closeEditRail
          )
        }
      }
    }
    .animation(.easeInOut(duration: 0.25), value: showsInspectorRail)
  }

  @ViewBuilder
  private var previewContent: some View {
    switch resolution {
    case .directFile(_, let projPath):
      if let filePath = selectedFilePath {
        inspectablePreview(
          url: URL(fileURLWithPath: filePath),
          isFileURL: true,
          allowingReadAccessTo: URL(fileURLWithPath: projPath),
          reloadToken: fileWatcher.reloadToken
        )
      }

    case .devServer:
      devServerContent

    case .noContent(let reason):
      noContentView(reason)

    case nil:
      resolvingContent
    }
  }

  // MARK: - Dev Server Content

  @ViewBuilder
  private var devServerContent: some View {
    switch serverState {
    case .idle, .detecting, .starting, .waitingForReady:
      loadingContent
    case .ready(let url):
      inspectablePreview(
        url: url,
        isFileURL: false,
        reloadToken: localhostReloadToken,
        onError: isExternalServer ? { error in
          handleExternalServerLoadFailure(error: error, failedURL: url)
        } : nil
      )
    case .failed(let error):
      failedContent(error)
    case .stopping:
      VStack(spacing: 12) {
        Spacer()
        ProgressView()
        Text("Stopping server...")
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - State Views

  private var resolvingContent: some View {
    VStack(spacing: 20) {
      Spacer()
      ProgressView()
        .controlSize(.large)
      Text("Detecting project...")
        .font(.headline)
        .foregroundColor(.secondary)
      Text("Analyzing \(session.projectName)...")
        .font(.caption)
        .foregroundColor(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var loadingContent: some View {
    VStack(spacing: 20) {
      Spacer()

      ProgressView()
        .controlSize(.large)

      Text(loadingMessage)
        .font(.headline)
        .foregroundColor(.secondary)

      Text("Starting dev server for \(session.projectName)...")
        .font(.caption)
        .foregroundColor(.secondary)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failedContent(_ error: String) -> some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.red.opacity(0.6))

      Text("Failed to Start Server")
        .font(.headline)
        .foregroundColor(.secondary)

      Text(error)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)

      Button("Retry") {
        Task { await DevServerManager.shared.startServer(for: serverKey, projectPath: projectPath) }
      }
      .buttonStyle(.borderedProminent)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func noContentView(_ reason: String) -> some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.secondary.opacity(0.6))

      Text("No Web Content")
        .font(.headline)
        .foregroundColor(.secondary)

      Text(reason)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var loadingMessage: String {
    switch serverState {
    case .detecting: return "Detecting project type..."
    case .starting(let msg): return msg
    case .waitingForReady: return "Starting dev server..."
    default: return "Preparing..."
    }
  }

  // MARK: - Helpers

  @MainActor
  private func loadPreview() async {
    if let agentURL = await WebPreviewAgentURLResolver.resolve(
      for: session,
      detectedLocalhostURL: agentLocalhostURL
    ) {
      if agentLocalhostURL == nil {
        AppLogger.devServer.info(
          "[WebPreview] Session \(session.id): recovered localhost URL from session file: \(agentURL.absoluteString)"
        )
      }
      await connectToAgentServer(agentURL)
      return
    }

    AppLogger.devServer.info("[WebPreview] Session \(session.id): no agent URL detected, resolving project at \(projectPath)")
    let result = await WebPreviewResolver.resolve(projectPath: projectPath)
    await applyResolution(result)

    if case .devServer = result {
      AppLogger.devServer.info("[WebPreview] Session \(session.id): starting own dev server")
      await DevServerManager.shared.startServer(for: serverKey, projectPath: projectPath)
    }
  }

  @MainActor
  private func connectToAgentServer(_ url: URL, logChange: Bool = false) async {
    let logPrefix = logChange ? "agent URL changed to" : "agent has localhost URL"
    AppLogger.devServer.info("[WebPreview] Session \(session.id): \(logPrefix) \(url.absoluteString), connecting directly")

    DevServerManager.shared.stopServer(for: serverKey)
    hasLoadedExternalContent = false
    await applyResolution(WebPreviewExternalRecovery.initial(projectPath: projectPath).resolution)
    DevServerManager.shared.connectToExistingServer(for: serverKey, url: url)
  }

  private func handleExternalServerLoadFailure(error: String, failedURL: URL) {
    Task {
      let shouldRecover = await MainActor.run {
        guard isCurrentExternalServerURL(failedURL) else {
          return false
        }

        let shouldFallback = WebPreviewExternalLoadFailurePolicy.shouldFallback(
          hasLoadedExternalContent: hasLoadedExternalContent,
          error: error
        )
        if !shouldFallback {
          AppLogger.devServer.info(
            "[WebPreview] Session \(session.id): ignoring external server load error during live preview: \(error)"
          )
        }
        return shouldFallback
      }
      guard shouldRecover else { return }

      AppLogger.devServer.error(
        "[WebPreview] Session \(session.id): failed to load external server \(failedURL.absoluteString): \(error)"
      )

      let staticPreviewResolution = await WebPreviewResolver.resolveStaticPreview(projectPath: projectPath)
      await MainActor.run {
        guard isCurrentExternalServerURL(failedURL) else { return }
        DevServerManager.shared.stopServer(for: serverKey)
      }
      let recovery = WebPreviewExternalRecovery.recovered(
        agentURL: failedURL,
        error: error,
        staticPreviewResolution: staticPreviewResolution
      )
      await applyResolution(recovery.resolution)
    }
  }

  @MainActor
  private func handleLocalhostReloadSignal(_ latestSignal: WebPreviewLocalhostReloadSignal?) {
    guard case .devServer = resolution else { return }

    let decision = WebPreviewLocalhostReloadSignal.decision(
      handledActivityID: handledCodeChangeActivityID,
      latestSignal: latestSignal,
      previewStartedAt: localhostPreviewStartedAt
    )

    switch decision {
    case .none:
      return
    case .captureBaseline(let activityID):
      handledCodeChangeActivityID = activityID
    case .reload(let activityID):
      handledCodeChangeActivityID = activityID
      scheduleLocalhostReload()
    }
  }

  @MainActor
  private func resetLocalhostReloadTracking() {
    localhostReloadTask?.cancel()
    localhostReloadTask = nil
    localhostPreviewStartedAt = Date()
    handledCodeChangeActivityID = latestLocalhostReloadSignal?.activityID
  }

  @MainActor
  private func scheduleLocalhostReload() {
    localhostReloadTask?.cancel()
    localhostReloadTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled,
            case .devServer = resolution else {
        return
      }

      localhostReloadToken = UUID()
    }
  }

  @MainActor
  private func applyResolution(_ newResolution: WebPreviewResolution) async {
    resolution = newResolution

    switch newResolution {
    case .directFile(let filePath, _):
      hasLoadedExternalContent = false
      localhostReloadTask?.cancel()
      localhostReloadTask = nil
      handledCodeChangeActivityID = nil
      selectedFilePath = filePath
      let directory = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
      fileWatcher.watch(directory: directory)
      await loadWebFileList()
    case .devServer:
      resetLocalhostReloadTracking()
      selectedFilePath = nil
      webRenderableFiles = []
      fileWatcher.stop()
    case .noContent:
      hasLoadedExternalContent = false
      localhostReloadTask?.cancel()
      localhostReloadTask = nil
      handledCodeChangeActivityID = nil
      selectedFilePath = nil
      webRenderableFiles = []
      fileWatcher.stop()
    }
  }

  @MainActor
  private func isCurrentExternalServerURL(_ url: URL) -> Bool {
    guard isExternalServer,
          case .ready(let currentURL) = serverState else {
      return false
    }

    return currentURL == url
  }

  private func loadWebFileList() async {
    let files = await WebPreviewResolver.findWebRenderableFiles(at: projectPath)
    webRenderableFiles = files.sorted {
      ($0.additions + $0.deletions) > ($1.additions + $1.deletions)
    }
  }

  @ViewBuilder
  private func inspectablePreview(
    url: URL,
    isFileURL: Bool,
    allowingReadAccessTo: URL? = nil,
    reloadToken: UUID? = nil,
    onError: ((String) -> Void)? = nil
  ) -> some View {
    Group {
      if inspectBehavior == .edit {
        InspectableWebView(
          url: url,
          isFileURL: isFileURL,
          allowingReadAccessTo: allowingReadAccessTo,
          onLoadingChange: { isLoading = $0 },
          onURLChange: { loadedURL in
            currentURL = loadedURL
            if isExternalServer, loadedURL != nil {
              hasLoadedExternalContent = true
            }
          },
          onError: onError,
          reloadToken: reloadToken,
          onElementSelected: { data in
            handleElementSelection(data)
          },
          isInspectModeActive: $inspectState.isActive,
          selectedElementId: inspectState.selectedElement?.id
        )
        .overlay(alignment: .top) {
          if inspectState.isActive {
            editModeBanner
          }
        }
      } else {
        InspectableWebView(
          url: url,
          isFileURL: isFileURL,
          allowingReadAccessTo: allowingReadAccessTo,
          onLoadingChange: { isLoading = $0 },
          onURLChange: { loadedURL in
            currentURL = loadedURL
            if isExternalServer, loadedURL != nil {
              hasLoadedExternalContent = true
            }
          },
          onError: onError,
          reloadToken: reloadToken,
          onElementSelected: { data in
            handleElementSelection(data)
          },
          isInspectModeActive: $inspectState.isActive,
          selectedElementId: inspectState.selectedElement?.id
        )
        .webInspectorOverlay(
          state: inspectState,
          onSubmit: { element, instruction in
            let prompt = ElementInspectorPromptBuilder.buildPrompt(
              element: element,
              instruction: instruction
            )
            onInspectSubmit?(prompt, session)
          },
          onContextSelection: { element in
            handleContextSelection(element)
          }
        )
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !queuedContext.isEmpty {
        WebPreviewQueuedContextView(
          queuedElements: queuedContext.elements,
          isSelectingContext: inspectState.isActive && inspectBehavior == .context,
          onRemoveElement: removeQueuedContextElement,
          onClearAll: clearQueuedContext
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: queuedContext.isEmpty)
  }

  private func toggleInspector() {
    if inspectState.isActive {
      deactivateInspector()
    } else {
      inspectState.activate(mode: inspectBehavior.canvasMode)
    }
  }

  private func deactivateInspector() {
    inspectState.deactivate()
    Task {
      await inspectorViewModel.closePanel()
    }
  }

  private func closeEditRail() {
    inspectState.dismissInput()
    Task {
      await inspectorViewModel.closePanel()
    }
  }

  private func handleElementSelection(_ element: ElementInspectorData) {
    inspectState.selectElement(element)

    guard inspectBehavior == .edit else { return }

    Task {
      await inspectorViewModel.inspect(
        element: element,
        previewFilePath: selectedFilePath,
        recentActivities: monitorState?.recentActivities ?? []
      )
    }
  }

  private func handleContextSelection(_ element: ElementInspectorData) {
    if let viewModel {
      viewModel.queueWebPreviewContext(element, for: session.id)
    } else {
      localContextQueue.append(element)
    }
  }

  private func clearQueuedContext() {
    if let viewModel {
      viewModel.clearQueuedWebPreviewContext(for: session.id)
    } else {
      localContextQueue.clear()
    }
  }

  private func removeQueuedContextElement(_ elementID: UUID) {
    if let viewModel {
      viewModel.removeQueuedWebPreviewContextElement(elementID, for: session.id)
    } else {
      localContextQueue.remove(id: elementID)
    }
  }

  private var editModeBanner: some View {
    HStack(spacing: 6) {
      Image(systemName: "slider.horizontal.3")
        .font(.system(size: 12))
        .foregroundColor(.white)

      Text(inspectorViewModel.isResolving ? "Edit Mode — mapping source" : "Edit Mode — click any element to edit")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)

      Spacer()

      Button {
        inspectState.deactivate()
        Task {
          await inspectorViewModel.closePanel()
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10))
          .foregroundColor(.white.opacity(0.8))
      }
      .buttonStyle(.plain)
      .help("Exit inspect mode (Esc)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.accentColor.opacity(0.9))
    .padding(12)
  }
}

// MARK: - Preview

#Preview {
  WebPreviewView(
    session: CLISession(
      id: "test-session-id",
      projectPath: "/Users/test/project",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 10,
      isActive: true
    ),
    projectPath: "/Users/test/project",
    onDismiss: {}
  )
}
