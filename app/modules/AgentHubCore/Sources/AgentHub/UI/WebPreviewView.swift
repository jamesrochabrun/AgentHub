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

// MARK: - WebPreviewView

/// Displays a web preview with smart resolution: loads static HTML files instantly
/// via `file://` URLs, or starts a dev server for framework projects.
public struct WebPreviewView: View {
  let session: CLISession
  let projectPath: String
  let onDismiss: () -> Void
  var isEmbedded: Bool = false

  @State private var isLoading: Bool = false
  @State private var currentURL: URL?
  @State private var resolution: WebPreviewResolution?
  @State private var selectedFilePath: String?
  @State private var webRenderableFiles: [GitDiffFileEntry] = []
  @State private var fileWatcher = WebPreviewFileWatcher()

  private var serverState: DevServerState {
    DevServerManager.shared.state(for: projectPath)
  }

  public init(
    session: CLISession,
    projectPath: String,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false
  ) {
    self.session = session
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
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
      let result = await WebPreviewResolver.resolve(projectPath: projectPath)
      resolution = result
      if case .devServer = result {
        await DevServerManager.shared.startServer(for: projectPath)
      }
      if case .directFile(let filePath, _) = result {
        selectedFilePath = filePath
        let dir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        fileWatcher.watch(directory: dir)
        await loadWebFileList()
      }
    }
    .onChange(of: selectedFilePath) { _, newPath in
      if let path = newPath {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        fileWatcher.watch(directory: dir)
      }
    }
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
    .onDisappear {
      fileWatcher.stop()
      if case .devServer = resolution {
        DevServerManager.shared.stopServer(for: projectPath)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "globe")
          .font(.title3)
          .foregroundColor(.brandPrimary)

        Text("Web Preview")
          .font(.title3.weight(.semibold))
      }

      Spacer()

      // Center: status/file info based on resolution
      centerIndicator

      Spacer()

      // Controls
      headerControls
    }
    .padding()
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
        if case .ready = serverState {
          Button(action: {
            DevServerManager.shared.stopServer(for: projectPath)
            Task { await DevServerManager.shared.startServer(for: projectPath) }
          }) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .medium))
          }
          .buttonStyle(.plain)
          .help("Restart server")

          Button(action: {
            DevServerManager.shared.stopServer(for: projectPath)
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
            Task { await DevServerManager.shared.startServer(for: projectPath) }
          }) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .medium))
          }
          .buttonStyle(.plain)
          .help("Retry")
        }

      default:
        EmptyView()
      }

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
        WebPreviewWebView(
          url: URL(fileURLWithPath: filePath),
          isFileURL: true,
          allowingReadAccessTo: URL(fileURLWithPath: projPath),
          isLoading: $isLoading,
          currentURL: $currentURL,
          onError: nil,
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
      WebPreviewWebView(
        url: url,
        isFileURL: false,
        allowingReadAccessTo: nil,
        isLoading: $isLoading,
        currentURL: $currentURL,
        onError: nil
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
        Task { await DevServerManager.shared.startServer(for: projectPath) }
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
