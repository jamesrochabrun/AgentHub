//
//  WebPreviewView.swift
//  AgentHub
//
//  Smart web preview that detects the project type and chooses the optimal
//  rendering strategy: instant file:// loading for static HTML, or dev server
//  for framework projects requiring transpilation.
//

import SwiftUI
import Canvas
import WebKit

private final class WebPreviewConsoleMessageHandler: NSObject, WKScriptMessageHandler {
  var onMessage: ((String, String) -> Void)?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let level = body["level"] as? String,
          let payload = body["message"] as? String else {
      return
    }
    onMessage?(level, payload)
  }
}

private enum WebPreviewAdvancedEditing {
#if DEBUG
  static let isSupported = true
#else
  static let isSupported = false
#endif
}

private enum WebPreviewInspectBehavior: String, CaseIterable, Identifiable {
  case input
  case crop
  case context
  case edit

  static func availableCases(advancedEditingEnabled: Bool) -> [WebPreviewInspectBehavior] {
    advancedEditingEnabled ? Self.allCases : [.input, .crop]
  }

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .input: return "square.and.pencil"
    case .crop: return "crop"
    case .context: return "square.and.arrow.up"
    case .edit: return "slider.horizontal.3"
    }
  }

  var helpText: String {
    switch self {
    case .input:
      return "Select an element, then type an instruction before sending it to the agent."
    case .crop:
      return "Drag to select a region, then describe the change you want."
    case .context:
      return "Queue selected elements in the preview to attach them to the next terminal message."
    case .edit:
      return "Select an element and edit its backing source file without sending anything to the terminal."
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .input: return "Instruction mode"
    case .crop: return "Crop region mode"
    case .context: return "Queued context mode"
    case .edit: return "Source edit mode"
    }
  }

  var modeName: String {
    switch self {
    case .input: return "inspect"
    case .crop: return "crop"
    case .context: return "context"
    case .edit: return "edit"
    }
  }

  var canvasMode: InspectMode {
    switch self {
    case .input: return .input
    case .crop: return .crop
    case .context: return .context
    case .edit: return .input
    }
  }
}

private enum WebPreviewReloadMode: Equatable {
  case none
  case directFileAutomatic
  case directFileManual
  case devServerAutomatic
  case devServerManual
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
  /// Reachability probe used before connecting to an agent-advertised URL.
  /// Injected so tests can substitute a deterministic mock.
  var reachabilityProbe: any LocalhostReachabilityProbing = LocalhostReachabilityProbe()

  @State private var isLoading: Bool = false
  @State private var resolution: WebPreviewResolution?
  @State private var selectedFilePath: String?
  @State private var webRenderableFiles: [GitDiffFileEntry] = []
  @State private var fileWatcher = WebPreviewFileWatcher()
  @State private var inspectState = ElementInspectState()
  @State private var inspectBehavior: WebPreviewInspectBehavior = .input
  @State private var localContextQueue = WebPreviewContextQueue()
  @State private var hasLoadedExternalContent = false
  @State private var manualReloadToken = UUID()
  @State private var localhostReloadToken: UUID?
  @State private var handledCodeChangeActivityID: UUID?
  @State private var localhostPreviewStartedAt = Date()
  @State private var localhostReloadTask: Task<Void, Never>?
  @State private var inspectorViewModel: WebPreviewInspectorViewModel
  @State private var lastSelectedSelector: String?
  @State private var previewWebView: WKWebView?
  @State private var consoleMessageHandler = WebPreviewConsoleMessageHandler()
  @State private var scrollRestorationCoordinator = WebPreviewScrollRestorationCoordinator()
  @State private var launchOptionsStatusOverride: String?
  @State private var askAgentReprobeTask: Task<Void, Never>?

  @AppStorage(AgentHubDefaults.webPreviewInspectorDataLevel)
  private var webPreviewInspectorDataLevelRawValue: String = ElementInspectorDataLevel.regular.rawValue

  @AppStorage(AgentHubDefaults.webPreviewAdvancedEditingEnabled)
  private var webPreviewAdvancedEditingEnabled: Bool = true

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
    monitorState: SessionMonitorState? = nil,
    reachabilityProbe: any LocalhostReachabilityProbing = LocalhostReachabilityProbe()
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.onInspectSubmit = onInspectSubmit
    self.viewModel = viewModel
    self.agentLocalhostURL = agentLocalhostURL
    self.monitorState = monitorState
    self.reachabilityProbe = reachabilityProbe
    self._inspectorViewModel = State(
      initialValue: WebPreviewInspectorViewModel(
        sessionID: session.id,
        projectPath: projectPath
      )
    )
  }

  private var queuedContext: WebPreviewContextQueue {
    viewModel?.queuedWebPreviewContextStore.queue(for: session.id) ?? localContextQueue
  }

  private var isAdvancedEditingEnabled: Bool {
#if DEBUG
    WebPreviewAdvancedEditing.isSupported && webPreviewAdvancedEditingEnabled
#else
    false
#endif
  }

  private var showsInspectorRail: Bool {
    isAdvancedEditingEnabled && inspectBehavior == .edit && inspectorViewModel.isPanelVisible
  }

  private var latestLocalhostReloadSignal: WebPreviewLocalhostReloadSignal? {
    WebPreviewLocalhostReloadSignal.latest(from: monitorState)
  }

  private var updateState: WebPreviewUpdateState {
    WebPreviewUpdateState.resolve(
      resolution: resolution,
      serverState: serverState,
      isEditMode: isAdvancedEditingEnabled && inspectBehavior == .edit
    )
  }

  private var configuredInspectorDataLevel: ElementInspectorDataLevel {
#if DEBUG
    ElementInspectorDataLevel(rawValue: webPreviewInspectorDataLevelRawValue) ?? .regular
#else
    .regular
#endif
  }

  private var activeSelectorToRestore: String? {
    guard !scrollRestorationCoordinator.suppressesSelectorRestore else { return nil }
    return lastSelectedSelector
  }

  private var reloadMode: WebPreviewReloadMode {
    let isManualReloadMode = isAdvancedEditingEnabled && inspectBehavior == .edit

    switch resolution {
    case .directFile:
      return isManualReloadMode ? .directFileManual : .directFileAutomatic
    case .devServer:
      return isManualReloadMode ? .devServerManual : .devServerAutomatic
    case .launchOptions, .noContent, nil:
      return .none
    }
  }

  private var requestedReloadToken: UUID? {
    switch reloadMode {
    case .directFileAutomatic:
      return fileWatcher.reloadToken
    case .devServerAutomatic:
      return localhostReloadToken
    case .directFileManual, .devServerManual:
      return manualReloadToken
    case .none:
      return nil
    }
  }

  private var effectiveReloadToken: UUID? {
    scrollRestorationCoordinator.effectiveReloadToken
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
    .onChange(of: reloadMode) { _, _ in
      syncReloadCoordinatorBaseline()
    }
    .onChange(of: fileWatcher.reloadToken) { _, newToken in
      guard reloadMode == .directFileAutomatic else { return }
      handleRequestedReloadTokenChange(newToken)
    }
    .onChange(of: localhostReloadToken) { _, newToken in
      guard reloadMode == .devServerAutomatic else { return }
      handleRequestedReloadTokenChange(newToken)
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
    .onChange(of: webPreviewAdvancedEditingEnabled) { _, _ in
      guard !isAdvancedEditingEnabled, inspectBehavior == .edit else { return }
      inspectBehavior = .input
    }
    .onChange(of: selectedFilePath) { _, newPath in
      if let path = newPath {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        fileWatcher.watch(directory: dir)
      } else {
        fileWatcher.stop()
      }
      syncReloadCoordinatorBaseline()
    }
    .onKeyPress(.escape) {
      if inspectState.isActive {
        if inspectState.selectedElement != nil {
          closeEditRail()
          return .handled
        }
        if inspectState.cropRect != nil {
          clearCropSelection()
          return .handled
        }
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
      askAgentReprobeTask?.cancel()
      askAgentReprobeTask = nil
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
    case .launchOptions:
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundColor(.orange)
        Text("Preview not running")
          .font(.caption)
          .foregroundColor(.secondary)
      }
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
      if canRefreshCurrentPreview {
        headerActionButton("Reload", systemImage: "arrow.clockwise", action: refreshPreview)
        .help("Refresh preview (⌘R)")

        // Hidden keyboard shortcut for Cmd+R
        Button("") {
          refreshPreview()
        }
        .keyboardShortcut("r", modifiers: .command)
        .hidden()
        .frame(width: 0, height: 0)
      }

      switch resolution {
      case .devServer:
        // Only show server control buttons for servers we manage (not the agent's)
        if !isExternalServer {
          if case .ready = serverState {
            headerActionButton("Restart", systemImage: "arrow.triangle.2.circlepath") {
              DevServerManager.shared.stopServer(for: serverKey)
              Task { await DevServerManager.shared.startServer(for: serverKey, projectPath: projectPath) }
            }
            .help("Restart server")

            headerActionButton("Stop", systemImage: "stop.circle") {
              DevServerManager.shared.stopServer(for: serverKey)
            }
            .help("Stop server")
          }

          if case .failed = serverState {
            headerActionButton("Retry", systemImage: "arrow.triangle.2.circlepath") {
              Task { await DevServerManager.shared.startServer(for: serverKey, projectPath: projectPath) }
            }
            .help("Retry")
          }
        }

      default:
        EmptyView()
      }

      if inspectState.isActive {
        let availableModes = WebPreviewInspectBehavior.availableCases(advancedEditingEnabled: isAdvancedEditingEnabled)
        if availableModes.count > 1 {
          HStack(spacing: 6) {
            ForEach(availableModes) { behavior in
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
      }

      // Inspect toggle
      Button {
        toggleInspector()
      } label: {
        Image(systemName: "cursorarrow.rays")
          .font(.system(size: 14, weight: .medium))
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

      if showsInspectorRail {
        Button("") {
          handleManualUpdate()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!updateState.isEnabled)
        .hidden()
        .frame(width: 0, height: 0)
      }

      Button("Close") {
        onDismiss()
      }
    }
    .animation(.easeInOut(duration: 0.2), value: inspectBehavior)
  }

  private func headerActionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.caption)
    }
    .webPreviewSecondaryButtonStyle()
    .controlSize(.small)
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
            updateState: updateState,
            onUpdate: handleManualUpdate,
            onClose: closeEditRail
          )
        }
      }
    }
    .animation(.easeInOut(duration: 0.25), value: showsInspectorRail)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !queuedContext.isEmpty {
        bottomBarContent
      }
    }
    .animation(.easeInOut(duration: 0.2), value: queuedContext.isEmpty)
  }

  @ViewBuilder
  private var previewContent: some View {
    switch resolution {
    case .directFile(_, let projPath):
      if let filePath = selectedFilePath {
        ZStack {
          inspectablePreview(
            url: URL(fileURLWithPath: filePath),
            isFileURL: true,
            allowingReadAccessTo: URL(fileURLWithPath: projPath),
            reloadToken: effectiveReloadToken
          )

          if isLoading {
            previewLoadingOverlay
          }
        }
      }

    case .devServer:
      devServerContent

    case .launchOptions(let options, let unreachableURL):
      WebPreviewLaunchOptionsView(
        launchOptions: options,
        statusMessage: launchOptionsStatusMessage(for: unreachableURL),
        onAskAgent: { askAgentToStartPreview(originalURL: unreachableURL) },
        onOpenStaticPreview: { openStaticFallback(options.staticPreviewResolution) }
      )

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
      ZStack {
        inspectablePreview(
          url: url,
          isFileURL: false,
          reloadToken: effectiveReloadToken,
          onError: { error in
            handleDevServerLoadFailure(error: error, failedURL: url)
          }
        )

        if isLoading {
          previewLoadingOverlay
        }
      }
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

  private var previewLoadingOverlay: some View {
    ZStack {
      Color.surfaceCanvas

      VStack(spacing: 18) {
        ProgressView()
          .controlSize(.large)

        Text(previewLoadingTitle)
          .font(.headline)
          .foregroundColor(.secondary)

        Text(previewLoadingSubtitle)
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(false)
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
      .webPreviewPrimaryButtonStyle()

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

      Text("No worries, ask your agent to run a local server again and reopen this window.")
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

  private var previewLoadingTitle: String {
    switch resolution {
    case .devServer:
      switch serverState {
      case .detecting:
        return "Detecting project type..."
      case .starting(let message):
        return message
      case .waitingForReady:
        return "Starting dev server..."
      case .ready:
        return "Reloading preview..."
      case .failed:
        return "Recovering preview..."
      case .idle, .stopping:
        return "Preparing preview..."
      }
    case .directFile:
      return "Loading preview..."
    case .launchOptions, .noContent, nil:
      return "Preparing preview..."
    }
  }

  private var previewLoadingSubtitle: String {
    switch resolution {
    case .devServer:
      if case .ready = serverState {
        return "Waiting for localhost to respond..."
      }
      return "Starting dev server for \(session.projectName)..."
    case .directFile:
      return "Rendering \(session.projectName)..."
    case .launchOptions, .noContent, nil:
      return "Preparing \(session.projectName)..."
    }
  }

  private var canRefreshCurrentPreview: Bool {
    guard previewWebView != nil, !isLoading else { return false }

    switch resolution {
    case .directFile:
      return selectedFilePath != nil
    case .devServer:
      if isExternalServer, case .ready = serverState {
        return true
      }
      return false
    case .launchOptions, .noContent, nil:
      return false
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
    AppLogger.devServer.info(
      "[WebPreview] Session \(session.id): \(logPrefix) \(url.absoluteString), probing reachability"
    )

    askAgentReprobeTask?.cancel()
    askAgentReprobeTask = nil

    let reachable = await reachabilityProbe.isReachable(url)
    guard reachable else {
      AppLogger.devServer.info(
        "[WebPreview] Session \(session.id): agent URL \(url.absoluteString) is not reachable — presenting launch options"
      )
      DevServerManager.shared.stopServer(for: serverKey)
      let resolution = await WebPreviewResolver.resolveLaunchOptions(
        projectPath: projectPath,
        unreachableURL: url
      )
      await applyResolution(resolution)
      return
    }

    AppLogger.devServer.info(
      "[WebPreview] Session \(session.id): reachable — connecting directly"
    )
    DevServerManager.shared.stopServer(for: serverKey)
    hasLoadedExternalContent = false
    launchOptionsStatusOverride = nil
    await applyResolution(WebPreviewExternalRecovery.initial(projectPath: projectPath).resolution)
    DevServerManager.shared.connectToExistingServer(for: serverKey, url: url)
  }

  // MARK: - Launch Options Actions

  private func launchOptionsStatusMessage(for unreachableURL: URL?) -> String? {
    if let launchOptionsStatusOverride { return launchOptionsStatusOverride }
    return unreachableURL.map { "Could not reach \($0.absoluteString)." }
  }

  private func askAgentToStartPreview(originalURL: URL?) {
    AppLogger.devServer.info(
      "[WebPreview] Session \(session.id): user chose Ask Agent from launch options"
    )
    let prompt: String
    if let originalURL {
      prompt = "Please restart the local dev server at \(originalURL.absoluteString)."
    } else {
      prompt = "Please start a local dev server for this project."
    }
    onInspectSubmit?(prompt, session)
    launchOptionsStatusOverride = "Asked the agent to start the preview. Waiting for a new localhost URL…"

    if let originalURL {
      startAskAgentReprobe(for: originalURL)
    }
  }

  /// Polls the previously advertised URL after "Ask Agent" so the preview
  /// auto-connects even when the agent restarts the server on the same URL
  /// (which would not fire `.onChange(of: agentLocalhostURL)`).
  private func startAskAgentReprobe(for url: URL) {
    askAgentReprobeTask?.cancel()
    let probe = reachabilityProbe
    askAgentReprobeTask = Task { @MainActor in
      let attempts = 20
      let delay: Duration = .milliseconds(750)
      for attempt in 0..<attempts {
        if Task.isCancelled { return }
        try? await Task.sleep(for: delay)
        if Task.isCancelled { return }
        if await probe.isReachable(url) {
          if Task.isCancelled { return }
          AppLogger.devServer.info(
            "[WebPreview] Session \(self.session.id): ask-agent reprobe succeeded on attempt \(attempt + 1)"
          )
          await connectToAgentServer(url, logChange: true)
          return
        }
      }
      if Task.isCancelled { return }
      launchOptionsStatusOverride = "Still waiting for the agent to start the preview. Click Ask Agent again if needed."
    }
  }

  private func openStaticFallback(_ resolution: WebPreviewResolution) {
    AppLogger.devServer.info(
      "[WebPreview] Session \(session.id): user chose Open Static Preview from launch options"
    )
    guard case .directFile = resolution else { return }
    launchOptionsStatusOverride = nil
    Task { @MainActor in
      await applyResolution(resolution)
    }
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

      // When there is no static fallback, promote the recovery into
      // launch options so the user still gets actionable choices
      // instead of a silent "No Web Content" dead-end.
      if case .noContent = recovery.resolution {
        let launchResolution = await WebPreviewResolver.resolveLaunchOptions(
          projectPath: projectPath,
          unreachableURL: failedURL
        )
        await applyResolution(launchResolution)
      } else {
        await applyResolution(recovery.resolution)
      }
    }
  }

  private func handleDevServerLoadFailure(error: String, failedURL: URL) {
    if isExternalServer {
      handleExternalServerLoadFailure(error: error, failedURL: failedURL)
      return
    }

    handleManagedServerLoadFailure(error: error, failedURL: failedURL)
  }

  private func handleManagedServerLoadFailure(error: String, failedURL: URL) {
    Task { @MainActor in
      guard isCurrentManagedServerURL(failedURL) else { return }

      let shouldRecover = WebPreviewExternalLoadFailurePolicy.shouldFallbackForManagedPreview(error: error)
      if !shouldRecover {
        AppLogger.devServer.info(
          "[WebPreview] Session \(session.id): ignoring managed server load error during live preview: \(error)"
        )
        return
      }

      AppLogger.devServer.error(
        "[WebPreview] Session \(session.id): failed to load managed server \(failedURL.absoluteString): \(error)"
      )

      let recovery = WebPreviewManagedRecovery.recovered(
        projectPath: projectPath,
        failedURL: failedURL,
        error: error
      )

      DevServerManager.shared.failServer(for: serverKey, error: recovery.failureMessage)
      launchOptionsStatusOverride = nil
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
    previewWebView = nil
    isLoading = false
    syncReloadCoordinatorBaseline()

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
    case .launchOptions:
      hasLoadedExternalContent = false
      localhostReloadTask?.cancel()
      localhostReloadTask = nil
      handledCodeChangeActivityID = nil
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

  @MainActor
  private func isCurrentManagedServerURL(_ url: URL) -> Bool {
    guard !isExternalServer,
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
      if isAdvancedEditingEnabled && inspectBehavior == .edit {
        InspectableWebView(
          url: url,
          isFileURL: isFileURL,
          inspectorDataLevel: .full,
          allowingReadAccessTo: allowingReadAccessTo,
          onLoadingChange: { loading in
            handlePreviewLoadingChange(loading)
          },
          onURLChange: { loadedURL in
            handlePreviewURLChange(loadedURL)
          },
          onError: onError,
          reloadToken: reloadToken,
          onElementSelected: { data in
            handleElementSelection(data)
          },
          onSelectedElementViewportRectChange: { rect in
            inspectState.updateSelectedElementViewportRect(rect)
          },
          isInspectModeActive: $inspectState.isActive,
          selectedElementId: inspectState.selectedElement?.id,
          selectorToRestore: activeSelectorToRestore,
          onWebViewReady: handleWebViewReady
        )
        .overlay(alignment: .top) {
          if inspectState.isActive {
            VStack(spacing: 8) {
              editModeBanner
              if let element = inspectorViewModel.selectedElement,
                 let toolbarValues = inspectorViewModel.toolbarValues {
                DesignToolbarContent(
                  values: toolbarValues,
                  element: element,
                  onEdit: inspectorViewModel.apply
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
              }
            }
          }
        }
      } else {
        InspectableWebView(
          url: url,
          isFileURL: isFileURL,
          inspectorDataLevel: configuredInspectorDataLevel,
          allowingReadAccessTo: allowingReadAccessTo,
          onLoadingChange: { loading in
            handlePreviewLoadingChange(loading)
          },
          onURLChange: { loadedURL in
            handlePreviewURLChange(loadedURL)
          },
          onError: onError,
          reloadToken: reloadToken,
          onElementSelected: { data in
            handleElementSelection(data)
          },
          onSelectedElementViewportRectChange: { rect in
            inspectState.updateSelectedElementViewportRect(rect)
          },
          onCropRectSelected: { rect, elements in
            inspectState.selectCropRect(rect, elements: elements)
          },
          onCropRectViewportChange: { rect in
            inspectState.updateCropRect(rect)
          },
          isInspectModeActive: $inspectState.isActive,
          inspectMode: inspectBehavior.canvasMode,
          selectedElementId: inspectState.selectedElement?.id,
          selectorToRestore: activeSelectorToRestore,
          onWebViewReady: handleWebViewReady
        )
        .webInspectorOverlay(
          state: inspectState,
          inputPlacement: .selectionAnchored,
          onSubmit: { element, instruction in
            let prompt = ElementInspectorPromptBuilder.buildPrompt(
              element: element,
              instruction: instruction
            )
            onInspectSubmit?(prompt, session)
          },
          onContextSelection: { element in
            handleContextSelection(element)
          },
          onCropSubmit: { rect, elements, instruction in
            handleCropSubmit(rect: rect, elements: elements, instruction: instruction)
          }
        )
      }
    }
  }

  private var bottomBarContent: some View {
    WebPreviewQueuedContextView(
      queuedElements: queuedContext.elements,
      isSelectingContext: inspectState.isActive && inspectBehavior == .context,
      onRemoveElement: removeQueuedContextElement,
      onClearAll: clearQueuedContext
    )
    .transition(.opacity.combined(with: .move(edge: .bottom)))
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
  }

  private func handleManualUpdate() {
    Task {
      await updateState.performUpdate(
        flushPendingWrites: {
          await inspectorViewModel.flushPendingWriteIfNeeded()
        },
        reload: {
          requestManualReload()
        }
      )
    }
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

  /// Clears the crop rectangle from both the Swift state (hides the input
  /// editor) and the Canvas JS overlay drawn inside the WKWebView. Without
  /// the bridge call the blue crop rectangle would remain visible on the
  /// page even after the editor disappears.
  private func clearCropSelection() {
    inspectState.dismissCropRect()
    if let previewWebView {
      ElementInspectorBridge.clearCropSelection(in: previewWebView)
    }
  }

  /// Reloads the current preview page using WKWebView's built-in reload.
  /// Works for every resolution (dev server, direct file, external URL)
  /// because it operates on whatever the web view is currently displaying.
  private func refreshPreview() {
    guard let previewWebView else { return }
    AppLogger.devServer.info("[WebPreview] Session \(session.id): user refreshed preview")
    previewWebView.reload()
  }

  private func handleOverlayReloadingState(_ loading: Bool) {
    guard inspectState.selectedElement != nil else { return }
    if loading {
      inspectState.isReloading = true
    } else {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        inspectState.isReloading = false
      }
    }
  }

  private func handlePreviewLoadingChange(_ loading: Bool) {
    isLoading = loading
    handleOverlayReloadingState(loading)

    guard !loading else { return }

    restorePendingScrollPositionIfNeeded()
    lastSelectedSelector = nil
    if let previewWebView {
      installConsoleHook(in: previewWebView)
    }
    beginPendingReloadCaptureIfNeeded()
  }

  private func handlePreviewURLChange(_ loadedURL: URL?) {
    if isExternalServer, loadedURL != nil {
      hasLoadedExternalContent = true
    }
    if let previewWebView {
      installConsoleHook(in: previewWebView)
    }
  }

  private func syncReloadCoordinatorBaseline() {
    scrollRestorationCoordinator.reset(to: requestedReloadToken)
  }

  private func handleRequestedReloadTokenChange(_ newToken: UUID?) {
    scrollRestorationCoordinator.queueReload(token: newToken)
    beginPendingReloadCaptureIfNeeded()
  }

  private func requestManualReload() {
    let newToken = UUID()
    manualReloadToken = newToken
    guard reloadMode == .directFileManual || reloadMode == .devServerManual else { return }
    handleRequestedReloadTokenChange(newToken)
  }

  private func beginPendingReloadCaptureIfNeeded() {
    guard !isLoading else { return }
    guard scrollRestorationCoordinator.beginCaptureIfNeeded() else { return }

    captureScrollPositionForPendingReload()
  }

  private func captureScrollPositionForPendingReload() {
    guard let previewWebView else {
      finishPendingReloadCapture(with: nil)
      return
    }

    previewWebView.evaluateJavaScript(Self.scrollCaptureScript) { result, error in
      let scrollPosition = WebPreviewScrollPosition.fromJavaScriptResult(result)
      if let error {
        AppLogger.devServer.debug(
          "[WebPreview] Session \(session.id): failed to capture scroll offset before reload: \(error.localizedDescription)"
        )
      }

      Task { @MainActor in
        finishPendingReloadCapture(with: scrollPosition)
      }
    }
  }

  private func finishPendingReloadCapture(with scrollPosition: WebPreviewScrollPosition?) {
    scrollRestorationCoordinator.finishCapture(with: scrollPosition)
  }

  private func restorePendingScrollPositionIfNeeded() {
    let scrollPosition = scrollRestorationCoordinator.consumePendingScrollPosition()
    guard let previewWebView,
          let scrollPosition else {
      return
    }

    previewWebView.evaluateJavaScript(Self.scrollRestoreScript(for: scrollPosition)) { _, error in
      if let error {
        AppLogger.devServer.debug(
          "[WebPreview] Session \(session.id): failed to restore scroll offset after reload: \(error.localizedDescription)"
        )
      }
    }
  }

  private func handleElementSelection(_ element: ElementInspectorData) {
    lastSelectedSelector = element.cssSelector
    inspectState.selectElement(element)

    guard isAdvancedEditingEnabled, inspectBehavior == .edit else { return }

    Task {
      await inspectorViewModel.inspect(
        element: element,
        previewFilePath: selectedFilePath,
        recentActivities: monitorState?.recentActivities ?? []
      )
    }
  }

  private func handleCropSubmit(rect: CGRect, elements: [ElementInspectorData], instruction: String) {
    Task { @MainActor in
      var screenshotPath: String? = nil
      if let webView = previewWebView {
        if let image = try? await ElementSnapshotCapture.captureSnapshot(of: rect, in: webView) {
          screenshotPath = saveCropScreenshot(image, sessionId: session.id)
        }
      }
      let prompt = ElementInspectorPromptBuilder.buildCropPrompt(
        cropRect: rect,
        elements: elements,
        instruction: instruction,
        screenshotPath: screenshotPath
      )
      onInspectSubmit?(prompt, session)
    }
  }

  private func saveCropScreenshot(_ image: NSImage, sessionId: String) -> String? {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
      return nil
    }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHub/crop-screenshots", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let filename = "crop-\(sessionId.prefix(8))-\(Int(Date().timeIntervalSince1970)).png"
    let fileURL = dir.appendingPathComponent(filename)
    do {
      try pngData.write(to: fileURL)
      return fileURL.path
    } catch {
      return nil
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

  private func handleWebViewReady(_ webView: WKWebView) {
    Task { @MainActor in
      previewWebView = webView
    }
    guard isAdvancedEditingEnabled else { return }
    inspectorViewModel.registerWebView(webView)
    consoleMessageHandler.onMessage = { level, message in
      Task { @MainActor in
        inspectorViewModel.appendConsoleEntry(level: level, message: message)
      }
    }
    let controller = webView.configuration.userContentController
    controller.removeScriptMessageHandler(forName: "agentHubConsole")
    controller.add(WeakScriptMessageHandler(consoleMessageHandler), name: "agentHubConsole")
    installConsoleHook(in: webView)
  }

  private func installConsoleHook(in webView: WKWebView) {
    guard isAdvancedEditingEnabled else { return }
    webView.evaluateJavaScript(Self.consoleHookScript) { _, _ in }
  }

  private static let consoleHookScript = """
    (function() {
      if (window.__agentHubConsoleHookInstalled) { return; }
      window.__agentHubConsoleHookInstalled = true;

      function serialize(value) {
        if (typeof value === 'string') { return value; }
        try { return JSON.stringify(value); } catch (error) { return String(value); }
      }

      ['log', 'warn', 'error'].forEach(function(level) {
        var original = console[level];
        console[level] = function() {
          var parts = Array.from(arguments).map(serialize).join(' ');
          try {
            window.webkit.messageHandlers.agentHubConsole.postMessage({
              level: level,
              message: parts
            });
          } catch (error) {}
          return original.apply(console, arguments);
        };
      });
    })();
  """

  private static let scrollCaptureScript = """
    [window.scrollX || window.pageXOffset || 0, window.scrollY || window.pageYOffset || 0]
  """

  private static func scrollRestoreScript(for position: WebPreviewScrollPosition) -> String {
    """
    (function() {
      const x = \(position.x);
      const y = \(position.y);
      const restore = function() { window.scrollTo(x, y); };
      restore();
      requestAnimationFrame(restore);
      setTimeout(restore, 50);
    })();
    """
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
