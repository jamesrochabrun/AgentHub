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
  /// Reactive localhost URL from the agent's session. When this changes, the preview updates.
  var agentLocalhostURL: URL?

  @State private var isLoading: Bool = false
  @State private var currentURL: URL?
  @State private var resolution: WebPreviewResolution?
  @State private var selectedFilePath: String?
  @State private var webRenderableFiles: [GitDiffFileEntry] = []
  @State private var fileWatcher = WebPreviewFileWatcher()
  @State private var inspectState = ElementInspectState()

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
    agentLocalhostURL: URL? = nil
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.onInspectSubmit = onInspectSubmit
    self.agentLocalhostURL = agentLocalhostURL
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
    .onChange(of: selectedFilePath) { _, newPath in
      if let path = newPath {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        fileWatcher.watch(directory: dir)
      }
    }
    .onKeyPress(.escape) {
      if inspectState.isActive {
        inspectState.deactivate()
        return .handled
      }
      onDismiss()
      return .handled
    }
    .onDisappear {
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

      // Inspect toggle
      Button {
        if inspectState.isActive {
          inspectState.deactivate()
        } else {
          inspectState.activate()
        }
      } label: {
        Image(systemName: "cursorarrow.click.2")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(inspectState.isActive ? .accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .help("Inspect Element (Cmd+Shift+I)")

      // Hidden keyboard shortcut
      Button("") {
        if inspectState.isActive {
          inspectState.deactivate()
        } else {
          inspectState.activate()
        }
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .hidden()
      .frame(width: 0, height: 0)

      Button("Close") {
        onDismiss()
      }
    }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch resolution {
    case .directFile(_, let projPath):
      if let filePath = selectedFilePath {
        InspectableWebView(
          url: URL(fileURLWithPath: filePath),
          isFileURL: true,
          allowingReadAccessTo: URL(fileURLWithPath: projPath),
          onLoadingChange: { isLoading = $0 },
          onURLChange: { currentURL = $0 },
          onError: nil,
          reloadToken: fileWatcher.reloadToken,
          onElementSelected: { data in inspectState.selectElement(data) },
          isInspectModeActive: $inspectState.isActive,
          selectedElementId: inspectState.selectedElement?.id
        )
        .webInspectorOverlay(state: inspectState) { element, instruction in
          let prompt = ElementInspectorPromptBuilder.buildPrompt(
            element: element, instruction: instruction
          )
          onInspectSubmit?(prompt, session)
        }
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
      InspectableWebView(
        url: url,
        isFileURL: false,
        allowingReadAccessTo: nil,
        onLoadingChange: { isLoading = $0 },
        onURLChange: { currentURL = $0 },
        onError: isExternalServer ? { error in
          handleExternalServerLoadFailure(error: error, failedURL: url)
        } : nil,
        onElementSelected: { data in inspectState.selectElement(data) },
        isInspectModeActive: $inspectState.isActive,
        selectedElementId: inspectState.selectedElement?.id
      )
      .webInspectorOverlay(state: inspectState) { element, instruction in
        let prompt = ElementInspectorPromptBuilder.buildPrompt(
          element: element, instruction: instruction
        )
        onInspectSubmit?(prompt, session)
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
    await applyResolution(WebPreviewExternalRecovery.initial(projectPath: projectPath).resolution)
    DevServerManager.shared.connectToExistingServer(for: serverKey, url: url)
  }

  private func handleExternalServerLoadFailure(error: String, failedURL: URL) {
    Task {
      let shouldRecover = await MainActor.run { isCurrentExternalServerURL(failedURL) }
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
  private func applyResolution(_ newResolution: WebPreviewResolution) async {
    resolution = newResolution

    switch newResolution {
    case .directFile(let filePath, _):
      selectedFilePath = filePath
      let directory = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
      fileWatcher.watch(directory: directory)
      await loadWebFileList()
    case .devServer, .noContent:
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
