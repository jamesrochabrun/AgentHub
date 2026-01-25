//
//  SessionDetailWindow.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import SwiftUI

// MARK: - SessionDetailWindow

/// A detached window view for displaying a single session with its assigned color as background.
/// Used with WindowGroup(for: String.self) where the String is the session ID.
/// Shows SessionMonitorPanel with terminal view for the session.
public struct SessionDetailWindow: View {
  /// The session ID to display
  let sessionId: String

  /// Access to the sessions view model directly for proper @Observable tracking
  /// This ensures color changes trigger re-renders in real-time
  @Environment(CLISessionsViewModel.self) private var viewModel: CLISessionsViewModel?

  /// Access to AgentHub environment for services
  @Environment(\.agentHub) private var agentHubProvider

  /// Local view mode state (synced with viewModel when available)
  @State private var viewMode: SessionViewMode = .conversation

  /// Whether to show the terminal (true) or conversation/activity view (false)
  @State private var showTerminal: Bool = false

  /// View model for headless mode conversations
  @State private var headlessViewModel = HeadlessSessionViewModel()

  public init(sessionId: String) {
    self.sessionId = sessionId
  }

  public var body: some View {
    ZStack {
      // Background color based on session's assigned color
      backgroundColor
        .ignoresSafeArea()

      VStack(spacing: 0) {
        if let session = findSession(), let viewModel = viewModel {
          // Header with session identifier and view mode toggle
          sessionHeader(session: session)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

          // SessionMonitorPanel with dynamic view mode
          // Note: ContextWindowBar is displayed inside SessionMonitorPanel
          SessionMonitorPanel(
            state: viewModel.monitorStates[sessionId],
            showTerminal: showTerminal,
            viewMode: viewMode,
            terminalKey: sessionId,
            sessionId: sessionId,
            projectPath: session.projectPath,
            claudeClient: viewModel.claudeClient,
            initialPrompt: nil,
            viewModel: viewModel,
            headlessViewModel: headlessViewModel,
            onPromptConsumed: nil,
            onSendMessage: { message in
              sendMessageToTerminal(message)
            }
          )
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
        } else {
          noSessionView
            .padding(24)
        }
      }
    }
    .frame(minWidth: 600, minHeight: 450)
    .onAppear {
      // Register detached window to hide terminal in main view
      viewModel?.registerDetachedWindow(for: sessionId)
      // Sync view mode from viewModel if available
      if let vm = viewModel {
        viewMode = vm.viewMode(for: sessionId)
      }
      // Configure headless view model with service from environment
      if let provider = agentHubProvider {
        headlessViewModel.configure(with: provider.headlessService)
      }
    }
    .onDisappear {
      // Unregister detached window to restore terminal in main view
      viewModel?.unregisterDetachedWindow(for: sessionId)
    }
  }

  // MARK: - Send Message

  /// Sends a message to the terminal for this session
  private func sendMessageToTerminal(_ message: String) {
    guard let viewModel = viewModel else { return }
    let key = sessionId
    if let terminal = viewModel.activeTerminals[key] {
      terminal.sendMessage(message)
    }
  }

  // MARK: - Background Color

  private var backgroundColor: Color {
    guard let colorHex = viewModel?.getSessionColor(for: sessionId) else {
      // Default subtle background if no color assigned
      return Color.surfaceCanvas
    }
    return Color(hex: colorHex).opacity(0.15)
  }

  // MARK: - Session Header

  @ViewBuilder
  private func sessionHeader(session: CLISession) -> some View {
    HStack(spacing: 8) {
      // Session slug or short ID (prefer slug, fallback to shortId)
      if let slug = session.slug {
        Text(slug)
          .font(.system(.headline, design: .monospaced, weight: .semibold))
          .foregroundColor(.primary)
      } else {
        Text(session.shortId)
          .font(.system(.headline, design: .monospaced, weight: .semibold))
          .foregroundColor(.primary)
      }

      Spacer()

      // View mode toggle (conversation/terminal)
      viewModeToggle

      // Status indicator
      Circle()
        .fill(session.isActive ? Color.green : Color.gray.opacity(0.5))
        .frame(width: 8, height: 8)
    }
  }

  // MARK: - View Mode Toggle

  /// Segmented control for switching between conversation, headless, and terminal views
  private var viewModeToggle: some View {
    HStack(spacing: 0) {
      // Conversation button (file-based parsing)
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) {
          showTerminal = false
          viewMode = .conversation
          viewModel?.setViewMode(.conversation, for: sessionId)
        }
      }) {
        Image(systemName: "bubble.left.and.bubble.right")
          .font(.caption)
          .frame(width: 28, height: 20)
          .foregroundColor(viewMode == .conversation && !showTerminal ? .white : .secondary)
          .background(viewMode == .conversation && !showTerminal ? Color.brandPrimary : Color.clear)
          .clipShape(Capsule())
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Conversation view (parses terminal output)")

      // Headless button (streaming JSONL)
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) {
          showTerminal = false
          viewMode = .headless
          viewModel?.setViewMode(.headless, for: sessionId)
        }
      }) {
        Image(systemName: "sparkles")
          .font(.caption)
          .frame(width: 28, height: 20)
          .foregroundColor(viewMode == .headless && !showTerminal ? .white : .secondary)
          .background(viewMode == .headless && !showTerminal ? Color.brandPrimary : Color.clear)
          .clipShape(Capsule())
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Headless mode (streaming JSON)")

      // Terminal button
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) {
          showTerminal = true
          viewMode = .terminal
          viewModel?.setViewMode(.terminal, for: sessionId)
        }
      }) {
        Image(systemName: "terminal")
          .font(.caption)
          .frame(width: 28, height: 20)
          .foregroundColor(showTerminal ? .white : .secondary)
          .background(showTerminal ? Color.brandPrimary : Color.clear)
          .clipShape(Capsule())
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Terminal view")
    }
    .padding(2)
    .background(Color.secondary.opacity(0.15))
    .clipShape(Capsule())
    .animation(.easeInOut(duration: 0.2), value: viewMode)
    .animation(.easeInOut(duration: 0.2), value: showTerminal)
  }

  // MARK: - No Session View

  private var noSessionView: some View {
    VStack(spacing: 12) {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("Session Not Found")
        .font(.headline)
        .foregroundColor(.primary)
      Text("ID: \(sessionId.prefix(8))...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Helpers

  private func findSession() -> CLISession? {
    viewModel?.findSession(byId: sessionId)
  }
}

// MARK: - Preview

/// Mock preview showing the window layout with sample data
private struct SessionDetailWindowMockPreview: View {
  let colorHex: String?

  @State private var showTerminal: Bool = false
  @State private var viewMode: SessionViewMode = .conversation
  @State private var headlessViewModel = HeadlessSessionViewModel()

  static let mockSession = CLISession(
    id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
    projectPath: "/Users/demo/Projects/MyApp",
    branchName: "feature/new-ui",
    isWorktree: true,
    lastActivityAt: Date(),
    messageCount: 42,
    isActive: true,
    firstMessage: "Help me build a new feature",
    lastMessage: "Implementing the UI components now",
    slug: "cosmic-purple-nebula"
  )

  static let mockMonitorState = SessionMonitorState(
    status: .thinking,
    currentTool: nil,
    lastActivityAt: Date(),
    inputTokens: 45000,
    outputTokens: 1200,
    totalOutputTokens: 5600,
    model: "claude-sonnet-4-20250514",
    recentActivities: [
      ActivityEntry(
        timestamp: Date().addingTimeInterval(-30),
        type: .userMessage,
        description: "Add a color picker to the sidebar"
      ),
      ActivityEntry(
        timestamp: Date().addingTimeInterval(-20),
        type: .toolUse(name: "Read"),
        description: "CLISessionRow.swift"
      ),
      ActivityEntry(
        timestamp: Date().addingTimeInterval(-10),
        type: .toolResult(name: "Read", success: true),
        description: "Completed"
      ),
      ActivityEntry(
        timestamp: Date(),
        type: .thinking,
        description: "Analyzing the code structure..."
      )
    ]
  )

  var backgroundColor: Color {
    if let hex = colorHex {
      return Color(hex: hex).opacity(0.15)
    }
    return Color.surfaceCanvas
  }

  var body: some View {
    ZStack {
      backgroundColor
        .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header with toggle
        HStack(spacing: 8) {
          // Session slug or short ID (prefer slug)
          if let slug = Self.mockSession.slug {
            Text(slug)
              .font(.system(.headline, design: .monospaced, weight: .semibold))
              .foregroundColor(.primary)
          } else {
            Text(Self.mockSession.shortId)
              .font(.system(.headline, design: .monospaced, weight: .semibold))
              .foregroundColor(.primary)
          }

          Spacer()

          // View mode toggle
          HStack(spacing: 0) {
            Button(action: {
              withAnimation(.easeInOut(duration: 0.2)) {
                showTerminal = false
                viewMode = .conversation
              }
            }) {
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.caption)
                .frame(width: 28, height: 20)
                .foregroundColor(viewMode == .conversation && !showTerminal ? .white : .secondary)
                .background(viewMode == .conversation && !showTerminal ? Color.brandPrimary : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: {
              withAnimation(.easeInOut(duration: 0.2)) {
                showTerminal = false
                viewMode = .headless
              }
            }) {
              Image(systemName: "sparkles")
                .font(.caption)
                .frame(width: 28, height: 20)
                .foregroundColor(viewMode == .headless && !showTerminal ? .white : .secondary)
                .background(viewMode == .headless && !showTerminal ? Color.brandPrimary : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: {
              withAnimation(.easeInOut(duration: 0.2)) {
                showTerminal = true
                viewMode = .terminal
              }
            }) {
              Image(systemName: "terminal")
                .font(.caption)
                .frame(width: 28, height: 20)
                .foregroundColor(showTerminal ? .white : .secondary)
                .background(showTerminal ? Color.brandPrimary : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
          }
          .padding(2)
          .background(Color.secondary.opacity(0.15))
          .clipShape(Capsule())

          // Status indicator
          Circle()
            .fill(Self.mockSession.isActive ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)

        // Monitor panel (mock - with conversation view and input)
        SessionMonitorPanel(
          state: Self.mockMonitorState,
          showTerminal: showTerminal,
          viewMode: viewMode,
          terminalKey: Self.mockSession.id,
          sessionId: Self.mockSession.id,
          projectPath: Self.mockSession.projectPath,
          claudeClient: nil,
          initialPrompt: nil,
          viewModel: nil,
          headlessViewModel: headlessViewModel,
          onPromptConsumed: nil,
          onSendMessage: { message in
            print("Preview: Message sent - \(message)")
          }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
      }
    }
    .frame(minWidth: 600, minHeight: 450)
    .onAppear {
      // Populate headless view model with mock conversation data
      headlessViewModel.sessionId = "mock-headless-session"
      headlessViewModel.messages = [
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-60),
          content: .user(text: "Help me build a new feature")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-55),
          content: .assistant(text: "I'll help you build that feature. Let me first explore the codebase to understand the current structure.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-50),
          content: .toolUse(name: "Glob", input: "**/*.swift", id: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-45),
          content: .toolResult(name: "Glob", success: true, toolUseId: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-40),
          content: .assistant(text: "I found the relevant files. Now I'll read the main components to understand the patterns.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-35),
          content: .toolUse(name: "Read", input: "CLISessionRow.swift", id: "tool-2")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-30),
          content: .toolResult(name: "Read", success: true, toolUseId: "tool-2")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-25),
          content: .assistant(text: "Implementing the UI components now. I'll create a new view that follows the existing patterns.")
        )
      ]
    }
  }
}

/// Headless mode preview showing the sparkles view mode with active conversation
private struct SessionDetailWindowHeadlessMockPreview: View {
  @State private var showTerminal: Bool = false
  @State private var viewMode: SessionViewMode = .headless  // Start in headless mode
  @State private var headlessViewModel = HeadlessSessionViewModel()

  static let mockSession = CLISession(
    id: "headless-demo-session",
    projectPath: "/Users/demo/Projects/HeadlessApp",
    branchName: "feature/streaming",
    isWorktree: false,
    lastActivityAt: Date(),
    messageCount: 15,
    isActive: true,
    firstMessage: "Create a real-time streaming parser",
    lastMessage: "Parsing JSONL events...",
    slug: "streaming-parser"
  )

  static let mockMonitorState = SessionMonitorState(
    status: .executingTool(name: "Read"),
    currentTool: "Read",
    lastActivityAt: Date(),
    inputTokens: 32000,
    outputTokens: 950,
    totalOutputTokens: 3200,
    model: "claude-opus-4-20250514",
    recentActivities: []
  )

  var body: some View {
    ZStack {
      Color.surfaceCanvas
        .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header with toggle
        HStack(spacing: 8) {
          if let slug = Self.mockSession.slug {
            Text(slug)
              .font(.system(.headline, design: .monospaced, weight: .semibold))
              .foregroundColor(.primary)
          }

          Spacer()

          // View mode toggle
          HStack(spacing: 0) {
            Button(action: {
              withAnimation(.easeInOut(duration: 0.2)) {
                showTerminal = false
                viewMode = .conversation
              }
            }) {
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.caption)
                .frame(width: 28, height: 20)
                .foregroundColor(viewMode == .conversation && !showTerminal ? .white : .secondary)
                .background(viewMode == .conversation && !showTerminal ? Color.brandPrimary : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: {
              withAnimation(.easeInOut(duration: 0.2)) {
                showTerminal = false
                viewMode = .headless
              }
            }) {
              Image(systemName: "sparkles")
                .font(.caption)
                .frame(width: 28, height: 20)
                .foregroundColor(viewMode == .headless && !showTerminal ? .white : .secondary)
                .background(viewMode == .headless && !showTerminal ? Color.brandPrimary : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: {
              withAnimation(.easeInOut(duration: 0.2)) {
                showTerminal = true
                viewMode = .terminal
              }
            }) {
              Image(systemName: "terminal")
                .font(.caption)
                .frame(width: 28, height: 20)
                .foregroundColor(showTerminal ? .white : .secondary)
                .background(showTerminal ? Color.brandPrimary : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
          }
          .padding(2)
          .background(Color.secondary.opacity(0.15))
          .clipShape(Capsule())

          // Status indicator
          Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)

        // Monitor panel in headless mode
        SessionMonitorPanel(
          state: Self.mockMonitorState,
          showTerminal: showTerminal,
          viewMode: viewMode,
          terminalKey: Self.mockSession.id,
          sessionId: Self.mockSession.id,
          projectPath: Self.mockSession.projectPath,
          claudeClient: nil,
          initialPrompt: nil,
          viewModel: nil,
          headlessViewModel: headlessViewModel,
          onPromptConsumed: nil,
          onSendMessage: { message in
            print("Preview: Message sent - \(message)")
          }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
      }
    }
    .frame(minWidth: 600, minHeight: 450)
    .onAppear {
      // Populate with headless streaming conversation
      headlessViewModel.sessionId = "headless-streaming-demo"
      headlessViewModel.isProcessing = true
      headlessViewModel.messages = [
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-120),
          content: .user(text: "Create a real-time streaming parser for JSONL events")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-115),
          content: .assistant(text: "I'll create a streaming JSONL parser for you. Let me first check the existing codebase structure.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-110),
          content: .toolUse(name: "Glob", input: "**/Services/*.swift", id: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-105),
          content: .toolResult(name: "Glob", success: true, toolUseId: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-100),
          content: .assistant(text: "Found the Services directory. I'll create a new service following your existing patterns.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-95),
          content: .toolUse(name: "Read", input: "Services/CLISessionMonitorService.swift", id: "tool-2")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-90),
          content: .toolResult(name: "Read", success: true, toolUseId: "tool-2")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-85),
          content: .assistant(text: "Great pattern here! I'll create a similar actor-based service for JSONL streaming. Let me write the implementation.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-80),
          content: .toolUse(name: "Write", input: "Services/JSONLStreamParser.swift", id: "tool-3")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-75),
          content: .toolResult(name: "Write", success: true, toolUseId: "tool-3")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-70),
          content: .assistant(text: "Parser created. Now let me read the event types to ensure proper integration.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-65),
          content: .toolUse(name: "Read", input: "Models/ClaudeEvent.swift", id: "tool-4")
        )
      ]
    }
  }
}

#Preview("With Coral Color") {
  SessionDetailWindowMockPreview(colorHex: "#FF6B6B")
    .frame(width: 700, height: 500)
}

#Preview("With Blue Color") {
  SessionDetailWindowMockPreview(colorHex: "#4ECDC4")
    .frame(width: 700, height: 500)
}

#Preview("With Purple Color") {
  SessionDetailWindowMockPreview(colorHex: "#9B59B6")
    .frame(width: 700, height: 500)
}

#Preview("No Color") {
  SessionDetailWindowMockPreview(colorHex: nil)
    .frame(width: 700, height: 500)
}

#Preview("Headless Mode Active") {
  SessionDetailWindowHeadlessMockPreview()
    .frame(width: 700, height: 600)
}

#Preview("Session Not Found") {
  SessionDetailWindow(sessionId: "nonexistent-session-id")
    .agentHub()
    .frame(width: 700, height: 500)
}
