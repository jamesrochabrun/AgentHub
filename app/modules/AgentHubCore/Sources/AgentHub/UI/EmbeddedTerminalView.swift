//
//  EmbeddedTerminalView.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import AppKit
import SwiftTerm
import SwiftUI

// MARK: - NewlineShortcut

/// Controls which key combination inserts a newline in the embedded Claude Code terminal.
public enum NewlineShortcut: Int, CaseIterable {
  /// System default: option+return inserts newline (SwiftTerm native behavior, no interception)
  case system = 0
  /// cmd+return inserts newline; option+return submits like plain Enter
  case cmdReturn = 1
  /// shift+return inserts newline; option+return submits like plain Enter
  case shiftReturn = 2

  public var label: String {
    switch self {
    case .system: return "Default (⌥↩)"
    case .cmdReturn: return "⌘↩ Newline"
    case .shiftReturn: return "⇧↩ Newline"
    }
  }
}

// MARK: - SafeLocalProcessTerminalView

/// A ManagedLocalProcessTerminalView subclass that safely handles cleanup by stopping
/// data reception before process termination. This prevents crashes when the
/// terminal buffer receives data during deallocation.
class SafeLocalProcessTerminalView: ManagedLocalProcessTerminalView {
  private var _isStopped = false
  private let stopLock = NSLock()
  private var readyDebounceTask: Task<Void, Never>?

  /// Called once after the process has finished its initial output burst
  /// (i.e., the CLI prompt is rendered and ready for input).
  /// Uses a debounce: fires after data stops arriving for 300ms.
  var onProcessReady: (() -> Void)?

  var isStopped: Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return _isStopped
  }

  /// Call this BEFORE terminating the process to safely stop data reception.
  func stopReceivingData() {
    stopLock.lock()
    _isStopped = true
    stopLock.unlock()
    readyDebounceTask?.cancel()
    readyDebounceTask = nil
    onProcessReady = nil
  }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    guard !isStopped else { return }
    super.dataReceived(slice: slice)
    if onProcessReady != nil {
      // Reset debounce timer on each data chunk.
      // When data stops flowing for 300ms, the CLI has finished rendering.
      readyDebounceTask?.cancel()
      readyDebounceTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        self?.onProcessReady?()
        self?.onProcessReady = nil
        self?.readyDebounceTask = nil
      }
    }
  }
}

// MARK: - EmbeddedTerminalView

/// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView
/// Provides an embedded terminal for interacting with Claude sessions
public struct EmbeddedTerminalView: NSViewRepresentable {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @AppStorage(AgentHubDefaults.terminalFontSize) private var terminalFontSize: Double = 12
  @AppStorage(AgentHubDefaults.terminalFontFamily) private var terminalFontFamily: String = "SF Mono"

  let terminalKey: String  // Key for terminal storage (session ID or "pending-{pendingId}")
  let sessionId: String?  // Optional: nil for new sessions, set for resume
  let projectPath: String
  let cliConfiguration: CLICommandConfiguration
  let initialPrompt: String?  // Optional: prompt to include with resume command
  let initialInputText: String?  // Optional: text to prefill terminal input without Enter
  let viewModel: CLISessionsViewModel?  // For shared terminal storage
  let dangerouslySkipPermissions: Bool  // One-shot flag for new sessions
  let permissionModePlan: Bool  // One-shot flag: start session in plan mode
  let worktreeName: String?  // nil = no --worktree; "" = auto-name; non-empty = named
  let onUserInteraction: (() -> Void)?
  let onRequestShowEditor: (() -> Void)?
  let consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?

  public init(
    terminalKey: String,
    sessionId: String? = nil,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String? = nil,
    initialInputText: String? = nil,
    viewModel: CLISessionsViewModel? = nil,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    worktreeName: String? = nil,
    onUserInteraction: (() -> Void)? = nil,
    onRequestShowEditor: (() -> Void)? = nil,
    consumeQueuedWebPreviewContextOnSubmit: (() -> String?)? = nil
  ) {
    self.terminalKey = terminalKey
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.cliConfiguration = cliConfiguration
    self.initialPrompt = initialPrompt
    self.initialInputText = initialInputText
    self.viewModel = viewModel
    self.dangerouslySkipPermissions = dangerouslySkipPermissions
    self.permissionModePlan = permissionModePlan
    self.worktreeName = worktreeName
    self.onUserInteraction = onUserInteraction
    self.onRequestShowEditor = onRequestShowEditor
    self.consumeQueuedWebPreviewContextOnSubmit = consumeQueuedWebPreviewContextOnSubmit
  }

  public final class Coordinator {
    var standaloneTerminal: (any EmbeddedTerminalSurface)?
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  public func makeNSView(context: Context) -> EmbeddedTerminalHostView {
    let hostView = EmbeddedTerminalHostView()
    let isDark = colorScheme == .dark
    let terminal = resolveTerminal(context: context, isDark: isDark)
    applyCallbacks(to: terminal)
    hostView.mount(terminal, key: terminalKey)
    return hostView
  }

  public func updateNSView(_ nsView: EmbeddedTerminalHostView, context: Context) {
    let terminal = resolveTerminal(context: context, isDark: colorScheme == .dark)
    applyCallbacks(to: terminal)
    if !nsView.isMounted(terminal, key: terminalKey) {
      nsView.mount(terminal, key: terminalKey)
    }
    terminal.syncAppearance(isDark: colorScheme == .dark, fontSize: CGFloat(terminalFontSize), fontFamily: terminalFontFamily, theme: runtimeTheme)

    // If there's a pending prompt in the viewModel, send it (and clear it)
    // Use terminalKey (not sessionId) since it works for both pending and real sessions
    if let prompt = viewModel?.pendingPrompt(for: terminalKey) {
      terminal.resetPromptDeliveryFlag()
      terminal.sendPromptIfNeeded(prompt)
      viewModel?.clearPendingPrompt(for: terminalKey)
    }
  }

  private func resolveTerminal(context: Context, isDark: Bool) -> any EmbeddedTerminalSurface {
    if let viewModel {
      let terminal = viewModel.getOrCreateTerminal(
        forKey: terminalKey,
        sessionId: sessionId,
        projectPath: projectPath,
        cliConfiguration: cliConfiguration,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText,
        isDark: isDark,
        dangerouslySkipPermissions: dangerouslySkipPermissions,
        permissionModePlan: permissionModePlan,
        worktreeName: worktreeName
      )
      terminal.updateContext(terminalSessionKey: terminalKey, sessionViewModel: viewModel)
      return terminal
    }

    if let existing = context.coordinator.standaloneTerminal {
      return existing
    }

    let factory = agentHub?.terminalSurfaceFactory ?? DefaultEmbeddedTerminalSurfaceFactory()
    let terminal = factory.makeSurface(for: .storedPreference)
    terminal.configure(
      sessionId: sessionId,
      projectPath: projectPath,
      cliConfiguration: cliConfiguration,
      initialPrompt: initialPrompt,
      initialInputText: initialInputText,
      isDark: isDark,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      metadataStore: agentHub?.metadataStore
    )
    context.coordinator.standaloneTerminal = terminal
    return terminal
  }

  private func applyCallbacks(to terminal: any EmbeddedTerminalSurface) {
    terminal.onUserInteraction = onUserInteraction
    terminal.onRequestShowEditor = onRequestShowEditor
    terminal.consumeQueuedWebPreviewContextOnSubmit = consumeQueuedWebPreviewContextOnSubmit
  }
}

// MARK: - TerminalContainerView

/// Container view that manages the terminal lifecycle
public class TerminalContainerView: NSView, ManagedLocalProcessTerminalViewDelegate {
  var terminalView: SafeLocalProcessTerminalView?
  private var terminalPanelSession: TerminalPanelKit.Session<SafeLocalProcessTerminalView>?
  private var protectedAgentPanelID: RegularTerminalPanelID?
  private var protectedAgentTabID: RegularTerminalTabID?
  private var workspaceHostingView: NSHostingView<RegularTerminalWorkspaceView>?
  private var isConfigured = false
  private var hasDeliveredInitialPrompt = false
  private var hasPrefilledInitialInputText = false
  private var lastAppliedFontSize: CGFloat?
  private var lastAppliedFontFamily: String?
  private var lastAppliedIsDark: Bool?
  private var currentIsDark = true
  private var currentFontSize: CGFloat = 12
  private var currentFontFamily = "SF Mono"
  private var currentTheme: RuntimeTheme?
  private var terminalPidMap: [ObjectIdentifier: pid_t] = [:]
  private var localEventMonitor: Any?
  private var projectPath: String = ""
  private var configuredProcessProvider: SessionProviderKind?
  private var isRestoringWorkspace = false
  private var lastWorkspaceSnapshot: TerminalWorkspaceSnapshot?
  public var onUserInteraction: (() -> Void)?
  public var onRequestShowEditor: (() -> Void)?
  public var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  public var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)?
  var terminalSessionKey: String?
  weak var sessionViewModel: CLISessionsViewModel?
  var metadataStore: SessionMetadataStore?
  var terminateProcessCallCount = 0

  /// The PID of the current terminal process, if running
  public var currentProcessPID: Int32? {
    protectedAgentTab?.terminalView.currentProcessId ?? activeTab?.terminalView.currentProcessId
  }

  // MARK: - Lifecycle

  /// Terminate process on deallocation (safety net)
  deinit {
    if let localEventMonitor {
      NSEvent.removeMonitor(localEventMonitor)
    }
    terminateProcess()
  }

  /// Explicitly terminates the terminal process and its children.
  /// Call this before removing the terminal from activeTerminals to ensure cleanup.
  /// Safe to call multiple times - subsequent calls are no-ops.
  public func terminateProcess() {
    terminateProcessCallCount += 1
    for terminal in allTerminalViews {
      terminateAndUnregister(terminal)
    }
  }

  // MARK: - Configuration

  /// Restarts the terminal by terminating the current process and starting a new one.
  /// Use this to reload session history after external changes.
  public func restart(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration
  ) {
    terminateProcess()
    removeMountedContent()
    resetWorkspaceState()
    isConfigured = false
    hasDeliveredInitialPrompt = false  // Reset for fresh start
    hasPrefilledInitialInputText = false
    configure(sessionId: sessionId, projectPath: projectPath, cliConfiguration: cliConfiguration)
  }

  public func configure(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String? = nil,
    initialInputText: String? = nil,
    isDark: Bool = true,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    worktreeName: String? = nil,
    metadataStore: SessionMetadataStore? = nil
  ) {
    if let metadataStore {
      self.metadataStore = metadataStore
    }
    guard !isConfigured else { return }
    isConfigured = true
    self.projectPath = projectPath
    currentIsDark = isDark
    configuredProcessProvider = SessionProviderKind(cliMode: cliConfiguration.mode)

    let terminal = prepareTerminalView(isDark: isDark)
    terminal.projectPath = projectPath
    terminal.onOpenFile = { [weak self] path, line in
      if let self, let vm = self.sessionViewModel, let key = self.terminalSessionKey {
        vm.pendingFileOpen = (sessionId: key, filePath: path, lineNumber: line)
      }
    }
    installInteractionMonitorIfNeeded()

    // Start the CLI process
    startCLIProcess(
      terminal: terminal,
      sessionId: sessionId,
      projectPath: projectPath,
      cliConfiguration: cliConfiguration,
      initialPrompt: initialPrompt,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName
    )
    registerProcessIfNeeded(
      for: terminal,
      kind: .agentTerminal,
      provider: configuredProcessProvider,
      sessionId: sessionId,
      projectPath: projectPath,
      expectedExecutable: cliConfiguration.executableName
    )
    mountInitialWorkspace(
      terminal: terminal,
      role: .agent,
      panelRole: .primary,
      name: providerDisplayName,
      workingDirectory: resolvedProjectPath
    )

    if let initialInputText, !initialInputText.isEmpty {
      terminal.onProcessReady = { [weak self] in
        self?.typeInitialTextIfNeeded(initialInputText)
      }
    }
  }

  public func configureShell(
    projectPath: String,
    isDark: Bool = true,
    shellPath: String? = nil
  ) {
    guard !isConfigured else { return }
    isConfigured = true
    self.projectPath = projectPath
    currentIsDark = isDark
    configuredProcessProvider = sessionViewModel?.providerKind

    let terminal = prepareTerminalView(isDark: isDark)
    terminal.projectPath = projectPath
    terminal.onOpenFile = { [weak self] path, line in
      if let self, let vm = self.sessionViewModel, let key = self.terminalSessionKey {
        vm.pendingFileOpen = (sessionId: key, filePath: path, lineNumber: line)
      }
    }
    installInteractionMonitorIfNeeded()

    startShellProcess(
      terminal: terminal,
      projectPath: projectPath,
      shellPath: shellPath
    )
    registerProcessIfNeeded(
      for: terminal,
      kind: .auxiliaryShell,
      provider: sessionViewModel?.providerKind,
      sessionId: terminalSessionKey,
      projectPath: projectPath,
      expectedExecutable: nil
    )
    mountInitialWorkspace(
      terminal: terminal,
      role: .shell,
      panelRole: .primary,
      name: "Shell",
      workingDirectory: resolvedProjectPath
    )
  }

  /// Resets the prompt delivery flag so a new prompt can be sent.
  /// Call this before sendPromptIfNeeded when sending a follow-up prompt (e.g., from inline editor).
  public func resetPromptDeliveryFlag() {
    hasDeliveredInitialPrompt = false
  }

  /// Sends a prompt to the terminal (only once per terminal instance unless reset)
  public func sendPromptIfNeeded(_ prompt: String) {
    guard let terminal = protectedAgentTab?.terminalView else { return }
    guard !hasDeliveredInitialPrompt else { return }
    hasDeliveredInitialPrompt = true
    focusProtectedAgentTab()

    // Detect plan-feedback prefix: 3 down-arrows + Enter marks step-by-step delivery
    let planFeedbackPrefix = "\u{1B}[B\u{1B}[B\u{1B}[B\r"
    if prompt.hasPrefix(planFeedbackPrefix) {
      let feedback = String(prompt.dropFirst(planFeedbackPrefix.count))
      Task { @MainActor [weak terminal] in
        let down: [UInt8] = [0x1B, 0x5B, 0x42]  // ESC [ B = down arrow
        terminal?.send(down)
        try? await Task.sleep(for: .milliseconds(80))
        terminal?.send(down)
        try? await Task.sleep(for: .milliseconds(80))
        terminal?.send(down)
        try? await Task.sleep(for: .milliseconds(80))
        terminal?.send([13])                            // select option 4
        try? await Task.sleep(for: .milliseconds(150)) // wait for text input to open
        if !feedback.isEmpty {
          terminal?.send(txt: feedback)
          try? await Task.sleep(for: .milliseconds(100))
        }
        terminal?.send([13])                            // submit
      }
      return
    }

    // Normal prompt: send text then Enter
    terminal.send(txt: prompt)
    Task { @MainActor [weak terminal] in
      try? await Task.sleep(for: .milliseconds(100))
      terminal?.send([13])  // ASCII 13 = carriage return (Enter key)
    }
  }

  /// Sends a follow-up prompt directly to the running CLI and submits it.
  /// This path is for explicit user actions and must not be gated by initial
  /// prompt delivery state.
  public func submitPromptImmediately(_ prompt: String) -> Bool {
    guard let terminal = protectedAgentTab?.terminalView else { return false }
    focusProtectedAgentTab()
    terminal.send(TerminalPromptSubmissionPayload.textBytes(
      prompt: prompt,
      bracketedPasteMode: terminal.terminal?.bracketedPasteMode ?? false
    ))
    let delay = Self.submitDelay(forByteCount: prompt.utf8.count)
    Task { @MainActor [weak terminal] in
      try? await Task.sleep(for: delay)
      terminal?.send([0x0D])
    }
    return true
  }

  /// Scales the delay between pasting text and pressing Enter so the CLI
  /// has time to process larger payloads before receiving the submit signal.
  private static func submitDelay(forByteCount count: Int) -> Duration {
    switch count {
    case ..<500:   return .milliseconds(100)
    case ..<2000:  return .milliseconds(250)
    default:       return .milliseconds(500)
    }
  }

  /// Types text into the terminal WITHOUT pressing Enter.
  /// Used for drag-and-drop file paths where user adds context before submitting.
  public func typeText(_ text: String) {
    guard let terminal = activeTab?.terminalView ?? protectedAgentTab?.terminalView else { return }
    terminal.send(txt: text)
  }

  /// Prefills initial terminal input text once, without pressing Enter.
  public func typeInitialTextIfNeeded(_ text: String) {
    guard !text.isEmpty else { return }
    guard !hasPrefilledInitialInputText else { return }
    hasPrefilledInitialInputText = true
    focusProtectedAgentTab()
    protectedAgentTab?.terminalView.send(txt: text)
  }

  public func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String = "SF Mono", theme: RuntimeTheme? = nil) {
    currentIsDark = isDark
    currentFontSize = max(fontSize, 8)
    currentFontFamily = fontFamily
    currentTheme = theme
    updateColors(isDark: isDark, theme: theme)
    updateFont(size: fontSize, family: fontFamily)
  }

  /// Updates terminal font size and family.
  public func updateFont(size: CGFloat, family: String = "SF Mono") {
    let resolvedSize = max(size, 8)

    let font = NSFont(name: family, size: resolvedSize)
      ?? NSFont(name: "SF Mono", size: resolvedSize)
      ?? NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
    for terminal in allTerminalViews {
      terminal.font = font
    }
    lastAppliedFontSize = resolvedSize
    lastAppliedFontFamily = family
  }

  private var lastAppliedThemeId: String?

  /// Updates terminal colors from theme or falls back to default dark/light.
  /// Only background and cursor are themed — foreground and ANSI colors are left
  /// untouched to preserve Claude Code / Codex syntax highlighting.
  public func updateColors(isDark: Bool, theme: RuntimeTheme? = nil) {
    let themeId = theme?.id

    for terminal in allTerminalViews {
      // Theme terminal colors only apply in dark mode
      if isDark, let bg = theme?.terminalBackground {
        terminal.nativeBackgroundColor = bg
      } else if isDark {
        terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
      } else {
        // Match app light background
        terminal.nativeBackgroundColor = NSColor(Color.backgroundLight)
      }

      if isDark {
        terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)
      } else {
        terminal.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
      }

      if isDark, let cursor = theme?.terminalCursor {
        terminal.caretColor = cursor
      } else {
        terminal.caretColor = NSColor(red: 204/255, green: 120/255, blue: 92/255, alpha: 1.0)
      }

      terminal.needsDisplay = true
    }

    lastAppliedIsDark = isDark
    lastAppliedThemeId = themeId
  }

  private func applyInitialAppearance(to terminal: TerminalView, isDark: Bool) {
    let fontSize: CGFloat = 12
    lastAppliedFontSize = fontSize
    let font = NSFont(name: "SF Mono", size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    terminal.font = font

    if isDark {
      terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)
    } else {
      terminal.nativeBackgroundColor = NSColor(Color.backgroundLight)
      terminal.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    }

    lastAppliedIsDark = isDark
  }

  private func installInteractionMonitorIfNeeded() {
    guard localEventMonitor == nil else { return }
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
      guard let self else { return event }

      switch event.type {
      case .keyDown:
        guard let window = event.window ?? self.window,
              window === self.window else { break }
        guard let focusedTab = self.focusedTab(in: window) else { break }
        let terminal = focusedTab.terminalView
        self.syncSelection(to: focusedTab)

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isTerminalVisible = terminal.superview != nil && !terminal.isHidden && terminal.alphaValue > 0

        if let shortcut = RegularTerminalShortcut.action(for: event) {
          self.handleShortcut(shortcut, focusedTerminal: terminal)
          self.onUserInteraction?()
          return nil
        }

        if isTerminalVisible,
           self.isTerminalResponderActive(window: window, terminal: terminal),
           flags == .control,
           event.keyCode == 50,
           self.onRequestShowEditor != nil {
          self.onRequestShowEditor?()
          self.onUserInteraction?()
          return nil
        }

        // Typing shortcuts (require terminal to be first responder)
        guard isTerminalResponderActive(window: window, terminal: terminal) else { break }
        guard isProtectedAgentTab(focusedTab) else {
          self.onUserInteraction?()
          break
        }

        let shortcut = NewlineShortcut(
          rawValue: UserDefaults.standard.integer(forKey: AgentHubDefaults.terminalNewlineShortcut)
        ) ?? .system

        let isReturn = event.keyCode == 36

        let action = TerminalSubmitInterception.keyAction(
          shortcut: shortcut,
          isReturn: isReturn,
          flags: flags
        )
        let queuedContextPrompt: String?
        switch action {
        case .submit, .systemSubmit:
          queuedContextPrompt = self.consumeQueuedWebPreviewContextOnSubmit?()
        case .passthrough, .newline:
          queuedContextPrompt = nil
        }

        switch TerminalSubmitInterception.dispatch(for: action, queuedContextPrompt: queuedContextPrompt) {
        case .passthrough:
          self.onUserInteraction?()
        case .newline:
          terminal.send([0x1B, 0x0D])  // newline
          self.onUserInteraction?()
          return nil
        case .submit:
          terminal.send([0x0D])
          self.onUserInteraction?()
          return nil
        case .appendContextAndSubmit(let queuedContextPrompt):
          let fullText = "\n\n\(queuedContextPrompt)"
          terminal.send(TerminalPromptSubmissionPayload.textBytes(
            prompt: fullText,
            bracketedPasteMode: terminal.terminal?.bracketedPasteMode ?? false
          ))
          let delay = Self.submitDelay(forByteCount: fullText.utf8.count)
          Task { @MainActor [weak terminal] in
            try? await Task.sleep(for: delay)
            terminal?.send([0x0D])
          }
          self.onUserInteraction?()
          return nil
        }
      case .leftMouseUp:
        guard !ResizeInteractionSuppression.shared.shouldSuppressSelection else {
          return event
        }
        guard let window = event.window, window === self.window else { return event }
        if let tab = self.tab(containingMouseEvent: event) {
          self.syncSelection(to: tab)
          // Defer selection updates until after mouse handling completes.
          DispatchQueue.main.async { [weak self] in
            self?.onUserInteraction?()
          }
        }
      default:
        break
      }

      return event
    }
  }

  private func isTerminalResponderActive(window: NSWindow, terminal: NSView) -> Bool {
    guard let responder = window.firstResponder else { return false }
    if responder === terminal { return true }
    if let responderView = responder as? NSView {
      return responderView.isDescendant(of: terminal)
    }
    return false
  }

  private func configureTerminalAppearance(_ terminal: TerminalView, isDark: Bool) {
    applyInitialAppearance(to: terminal, isDark: isDark)

    // Set cursor color to match brand (bookCloth color)
    terminal.caretColor = NSColor(red: 204/255, green: 120/255, blue: 92/255, alpha: 1.0)
  }

  private func prepareTerminalView(isDark: Bool) -> SafeLocalProcessTerminalView {
    // Use a sensible fallback frame when bounds is zero (view not yet laid out by SwiftUI).
    // SwiftTerm calculates column/row count from the initial frame — a zero frame produces a
    // ~2-column terminal that wraps every character. Auto Layout will correct the size on the
    // next layout pass and SwiftTerm's setFrameSize override sends SIGWINCH to the process.
    let initialFrame = bounds.isEmpty ? CGRect(x: 0, y: 0, width: 800, height: 600) : bounds
    let terminal = SafeLocalProcessTerminalView(frame: initialFrame)
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminal.processDelegate = self

    configureTerminalAppearance(terminal, isDark: isDark)
    terminal.font = NSFont(name: currentFontFamily, size: currentFontSize)
      ?? NSFont(name: "SF Mono", size: currentFontSize)
      ?? NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)

    return terminal
  }

  private func startCLIProcess(
    terminal: ManagedLocalProcessTerminalView,
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String? = nil,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    worktreeName: String? = nil
  ) {
    let launch = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: sessionId,
      projectPath: projectPath,
      cliConfiguration: cliConfiguration,
      initialPrompt: initialPrompt,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      metadataStore: metadataStore
    )

    guard case .success(let launch) = launch else {
      // Show error in terminal
      let message = "Could not find '\(cliConfiguration.command)' command."
      terminal.feed(text: "\r\n\u{001B}[31mError: \(message)\u{001B}[0m\r\n")
      terminal.feed(text: "Please ensure the CLI is installed.\r\n")
      return
    }

#if DEBUG
    let workingDirectory = projectPath.isEmpty ? NSHomeDirectory() : projectPath
    let homeEnv = launch.environment["HOME"] ?? "<nil>"
    AppLogger.session.debug(
      "[ClaudeProcess] workingDirectory=\(workingDirectory, privacy: .public) homeEnv=\(homeEnv, privacy: .public) command=\(cliConfiguration.command, privacy: .public)"
    )
#endif

    terminal.startProcess(
      executable: launch.swiftTermExecutable,
      args: launch.swiftTermArguments,
      environment: launch.swiftTermEnvironment
    )
  }

  private func startShellProcess(
    terminal: ManagedLocalProcessTerminalView,
    projectPath: String,
    shellPath: String? = nil
  ) {
    let launch = EmbeddedTerminalLaunchBuilder.shellLaunch(
      projectPath: projectPath,
      shellPath: shellPath
    )

    terminal.startProcess(
      executable: launch.swiftTermExecutable,
      args: launch.swiftTermArguments,
      environment: launch.swiftTermEnvironment
    )
  }

  private func registerProcessIfNeeded(
    for terminal: SafeLocalProcessTerminalView,
    kind: ManagedProcessKind,
    provider: SessionProviderKind?,
    sessionId: String?,
    projectPath: String,
    expectedExecutable: String?
  ) {
    guard let pid = terminal.currentProcessId, pid > 0 else { return }
    let key = ObjectIdentifier(terminal)
    terminalPidMap[key] = pid
    let terminalKey = terminalSessionKey
    Task {
      await TerminalProcessRegistry.shared.register(
        pid: pid,
        kind: kind,
        provider: provider,
        terminalKey: terminalKey,
        sessionId: sessionId,
        projectPath: projectPath,
        expectedExecutable: expectedExecutable
      )
    }
  }

  private var resolvedProjectPath: String {
    projectPath.isEmpty ? NSHomeDirectory() : projectPath
  }

  private var providerDisplayName: String {
    (sessionViewModel?.providerKind ?? configuredProcessProvider)?.rawValue ?? "CLI"
  }

  private var panels: [RegularTerminalPanel] {
    terminalPanelSession?.panels ?? []
  }

  private var primaryPanelID: RegularTerminalPanelID? {
    terminalPanelSession?.primaryPanelID
  }

  private var activePanelID: RegularTerminalPanelID? {
    terminalPanelSession?.activePanelID
  }

  private var splitRoot: RegularTerminalSplitNode? {
    terminalPanelSession?.splitRoot
  }

  private var activePanel: RegularTerminalPanel? {
    terminalPanelSession?.activePanel
  }

  private var activeTab: RegularTerminalTab? {
    activePanel?.activeTab
  }

  private var protectedAgentTab: RegularTerminalTab? {
    guard let protectedAgentPanelID, let protectedAgentTabID else { return nil }
    return panels
      .first { $0.id == protectedAgentPanelID }?
      .tabs
      .first { $0.id == protectedAgentTabID }
  }

  private var allTabs: [RegularTerminalTab] {
    panels.flatMap(\.tabs)
  }

  private var allTerminalViews: [SafeLocalProcessTerminalView] {
    allTabs.map(\.terminalView)
  }

  private func mountInitialWorkspace(
    terminal: SafeLocalProcessTerminalView,
    role: TerminalWorkspaceTabRole,
    panelRole: TerminalWorkspacePanelRole,
    name: String?,
    workingDirectory: String?
  ) {
    let tab = RegularTerminalTab(
      role: role,
      name: name,
      workingDirectory: workingDirectory,
      terminalView: terminal
    )
    let panel = RegularTerminalPanel(
      role: panelRole,
      tabs: [tab],
      activeTabID: tab.id
    )

    terminalView = terminal
    terminalPanelSession = TerminalPanelKit.Session(primaryPanel: panel)

    if role == .agent {
      protectedAgentPanelID = panel.id
      protectedAgentTabID = tab.id
    }

    refreshWorkspaceRootView()
    syncAppearance(
      isDark: currentIsDark,
      fontSize: currentFontSize,
      fontFamily: currentFontFamily,
      theme: currentTheme
    )
    lastWorkspaceSnapshot = captureWorkspaceSnapshot()
  }

  private func resetWorkspaceState() {
    terminalPanelSession = nil
    protectedAgentPanelID = nil
    protectedAgentTabID = nil
    terminalView = nil
    lastWorkspaceSnapshot = nil
  }

  private func removeMountedContent() {
    workspaceHostingView?.removeFromSuperview()
    workspaceHostingView = nil
    for subview in subviews {
      subview.removeFromSuperview()
    }
  }

  private func refreshWorkspaceRootView() {
    guard !panels.isEmpty else {
      removeMountedContent()
      return
    }

    if let workspaceHostingView {
      workspaceHostingView.rootView = makeWorkspaceRootView()
      return
    }

    let host = NSHostingView(rootView: makeWorkspaceRootView())
    host.translatesAutoresizingMaskIntoConstraints = false
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.clear.cgColor
    addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    workspaceHostingView = host
  }

  private func makeWorkspaceRootView() -> RegularTerminalWorkspaceView {
    RegularTerminalWorkspaceView(
      panels: panels,
      splitRoot: splitRoot,
      activePanelID: activePanelID,
      canClosePanel: { [weak self] panel in
        self?.canCloseRegularPanel(panel) ?? false
      },
      canCloseTab: { [weak self] panel, tab in
        self?.canCloseRegularTab(tab, in: panel) ?? false
      },
      onActivatePanel: { [weak self] panel in
        self?.activateRegularPanel(panel)
      },
      onSelectTab: { [weak self] panel, tab in
        self?.selectRegularTab(tab, in: panel)
      },
      onClosePanel: { [weak self] panel in
        self?.closeRegularPanel(panel)
      },
      onCloseTab: { [weak self] panel, tab in
        self?.closeRegularTab(tab, in: panel)
      },
      onOpenTab: { [weak self] panel in
        self?.openShellTab(in: panel.id)
      },
      onSplitPanel: { [weak self] panel, axis in
        self?.openShellPane(axis: axis, anchorPanelID: panel.id)
      }
    )
  }

  private func makeShellTab(
    name: String? = "Shell",
    workingDirectory: String? = nil
  ) -> RegularTerminalTab {
    let shellProjectPath = resolvedExistingDirectory(workingDirectory)
    let terminal = prepareTerminalView(isDark: currentIsDark)
    terminal.projectPath = shellProjectPath
    terminal.onOpenFile = { [weak self] path, line in
      if let self, let vm = self.sessionViewModel, let key = self.terminalSessionKey {
        vm.pendingFileOpen = (sessionId: key, filePath: path, lineNumber: line)
      }
    }

    let tab = RegularTerminalTab(
      role: .shell,
      name: name,
      workingDirectory: shellProjectPath,
      terminalView: terminal
    )
    scheduleShellStart(for: tab, projectPath: shellProjectPath)
    return tab
  }

  private func scheduleShellStart(for tab: RegularTerminalTab, projectPath: String) {
    Task { @MainActor [weak self, weak tab] in
      await Task.yield()
      guard let self, let tab else { return }
      guard self.allTabs.contains(where: { $0.id == tab.id }) else { return }
      guard !tab.terminalView.isStopped else { return }

      self.startShellProcess(
        terminal: tab.terminalView,
        projectPath: projectPath,
        shellPath: nil
      )
      self.registerProcessIfNeeded(
        for: tab.terminalView,
        kind: .auxiliaryShell,
        provider: self.sessionViewModel?.providerKind ?? self.configuredProcessProvider,
        sessionId: self.terminalSessionKey,
        projectPath: projectPath,
        expectedExecutable: nil
      )
    }
  }

  private func openShellTab(in panelID: RegularTerminalPanelID? = nil) {
    guard RegularTerminalLaunchFeatures.tabsEnabled else { return }
    guard let session = terminalPanelSession else { return }
    guard let panel = panel(for: panelID ?? activePanelID ?? primaryPanelID) else { return }
    let tab = makeShellTab(workingDirectory: panel.activeTab?.workingDirectory)
    guard session.appendTab(tab, in: panel.id) else { return }
    refreshWorkspaceRootView()
    syncAppearance(
      isDark: currentIsDark,
      fontSize: currentFontSize,
      fontFamily: currentFontFamily,
      theme: currentTheme
    )
    notifyWorkspaceChanged()
    focus(tab)
  }

  private func openShellPane(
    axis: RegularTerminalSplitAxis = .horizontal,
    anchorPanelID: RegularTerminalPanelID? = nil
  ) {
    guard let session = terminalPanelSession, session.canOpenPanel else { return }
    guard let anchorPanel = panel(for: anchorPanelID ?? activePanelID ?? primaryPanelID) else { return }
    let tab = makeShellTab(workingDirectory: anchorPanel.activeTab?.workingDirectory)
    guard session.openPanel(with: tab, beside: anchorPanel.id, axis: axis) != nil else { return }
    refreshWorkspaceRootView()
    syncAppearance(
      isDark: currentIsDark,
      fontSize: currentFontSize,
      fontFamily: currentFontFamily,
      theme: currentTheme
    )
    notifyWorkspaceChanged()
    focus(tab)
  }

  private func canCloseRegularPanel(_ panel: RegularTerminalPanel) -> Bool {
    terminalPanelSession?.canClosePanel(panel.id) ?? false
  }

  private func canCloseRegularTab(_ tab: RegularTerminalTab, in panel: RegularTerminalPanel) -> Bool {
    guard RegularTerminalLaunchFeatures.tabsEnabled else { return false }
    return terminalPanelSession?.canCloseTab(
      tab.id,
      in: panel.id,
      isProtected: isProtectedAgentTab(tab, in: panel.id)
    ) ?? false
  }

  private func activateRegularPanel(_ panel: RegularTerminalPanel) {
    guard terminalPanelSession?.focusPanel(panel.id) == true else { return }
    notifyWorkspaceChanged()
  }

  private func selectRegularTab(_ tab: RegularTerminalTab, in panel: RegularTerminalPanel) {
    guard RegularTerminalLaunchFeatures.tabsEnabled || panel.activeTabID == tab.id else { return }
    guard terminalPanelSession?.selectTab(tab.id, in: panel.id) == true else { return }
    refreshWorkspaceRootView()
    notifyWorkspaceChanged()
    focus(tab)
  }

  private func closeRegularPanel(_ panel: RegularTerminalPanel) {
    guard canCloseRegularPanel(panel) else { return }
    let wasActivePanel = activePanelID == panel.id
    let closeResult = terminalPanelSession?.closePanel(panel.id) ?? .empty
    refreshWorkspaceRootView()
    notifyWorkspaceChanged()
    if wasActivePanel, let activeTab {
      focus(activeTab)
    }
    terminateAfterWorkspaceUpdate(closeResult.payloads)
  }

  private func closeRegularTab(_ tab: RegularTerminalTab, in panel: RegularTerminalPanel) {
    guard canCloseRegularTab(tab, in: panel) else { return }
    let wasActiveTab = panel.activeTabID == tab.id
    let closeResult = terminalPanelSession?.closeTab(tab.id, in: panel.id) ?? .empty
    refreshWorkspaceRootView()
    notifyWorkspaceChanged()
    if wasActiveTab, let replacementTab = activePanel?.activeTab {
      focus(replacementTab)
    }
    terminateAfterWorkspaceUpdate(closeResult.payloads)
  }

  private func closeActiveOrLastAuxiliaryPanel() {
    guard let activePanel else { return }
    if canCloseRegularPanel(activePanel) {
      closeRegularPanel(activePanel)
      return
    }
    if let auxiliary = panels.reversed().first(where: canCloseRegularPanel) {
      closeRegularPanel(auxiliary)
    }
  }

  private func focus(_ tab: RegularTerminalTab) {
    focusTerminalView(tab.terminalView)
  }

  func focusActiveTerminal() {
    focusTerminalView(activeTab?.terminalView ?? protectedAgentTab?.terminalView ?? terminalView)
  }

  private func focusTerminalView(_ terminal: SafeLocalProcessTerminalView?) {
    guard let terminal else { return }
    Task { @MainActor [weak terminal] in
      await Task.yield()
      guard let terminal, let window = terminal.window else { return }
      window.makeFirstResponder(terminal)
    }
  }

  private func terminateAfterWorkspaceUpdate(_ terminals: [SafeLocalProcessTerminalView]) {
    guard !terminals.isEmpty else { return }
    Task { @MainActor [weak self, terminals] in
      await Task.yield()
      guard let self else {
        for terminal in terminals {
          terminal.stopReceivingData()
          terminal.terminateProcessTree()
        }
        return
      }
      for terminal in terminals {
        self.terminateAndUnregister(terminal)
      }
    }
  }

  private func focusProtectedAgentTab() {
    guard let tab = protectedAgentTab,
          let protectedAgentPanelID,
          terminalPanelSession?.selectTab(tab.id, in: protectedAgentPanelID) == true else {
      return
    }
    refreshWorkspaceRootView()
    focus(tab)
  }

  private func handleShortcut(
    _ shortcut: RegularTerminalShortcut,
    focusedTerminal: SafeLocalProcessTerminalView
  ) {
    switch shortcut {
    case .startSearch:
      showFindPanel(in: focusedTerminal)
    case .openTab:
      guard RegularTerminalLaunchFeatures.tabsEnabled else { return }
      openShellTab()
    case .openPane(let axis):
      openShellPane(axis: axis)
    case .closePanel:
      closeActiveOrLastAuxiliaryPanel()
    case .focusPanel(let direction):
      if focusPanel(direction: direction) {
        notifyWorkspaceChanged()
      }
    case .selectTab(let direction):
      guard RegularTerminalLaunchFeatures.tabsEnabled else { return }
      if selectTab(direction: direction) {
        notifyWorkspaceChanged()
      }
    }
  }

  private func showFindPanel(in terminal: SafeLocalProcessTerminalView) {
    guard let window = terminal.window else { return }
    window.makeFirstResponder(terminal)
    let menuItem = NSMenuItem()
    menuItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    terminal.performFindPanelAction(menuItem)
  }

  private func focusPanel(direction: RegularTerminalPanelNavigationDirection) -> Bool {
    guard terminalPanelSession?.focusPanel(direction: direction, viewportSize: bounds.size) == true else {
      return false
    }
    refreshWorkspaceRootView()
    if let activeTab {
      focus(activeTab)
    }
    return true
  }

  private func selectTab(direction: RegularTerminalTabNavigationDirection) -> Bool {
    guard RegularTerminalLaunchFeatures.tabsEnabled else { return false }
    guard terminalPanelSession?.selectTab(direction: direction) == true else { return false }
    refreshWorkspaceRootView()
    if let activeTab {
      focus(activeTab)
    }
    return true
  }

  public func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? {
    guard !panels.isEmpty else { return nil }

    let panelSnapshots = panels.map { panel in
      let snapshot = tabsForWorkspaceSnapshot(in: panel)
      let tabs = snapshot.tabs.map { tab in
        TerminalWorkspaceTabSnapshot(
          role: tab.role,
          name: Self.nonEmpty(tab.name),
          title: Self.nonEmpty(tab.title),
          workingDirectory: Self.nonEmpty(tab.workingDirectory ?? resolvedProjectPath)
        )
      }
      return TerminalWorkspacePanelSnapshot(
        role: panel.id == primaryPanelID ? .primary : .auxiliary,
        tabs: tabs,
        activeTabIndex: snapshot.activeTabIndex
      )
    }

    return TerminalWorkspaceSnapshot(
      panels: panelSnapshots,
      activePanelIndex: panels.firstIndex { $0.id == activePanelID } ?? 0
    )
  }

  public func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) {
    guard !panels.isEmpty, !snapshot.panels.isEmpty else { return }
    isRestoringWorkspace = true
    defer {
      isRestoringWorkspace = false
      lastWorkspaceSnapshot = captureWorkspaceSnapshot()
    }

    resetToPrimaryTerminal()
    let panelSnapshots = normalizedPanelSnapshots(snapshot.panels)
    var restoredPanelIDs: [RegularTerminalPanelID] = []
    var restoredTabIDs: [[RegularTerminalTabID]] = []

    if let primary = panel(for: primaryPanelID) {
      restoredPanelIDs.append(primary.id)
      var primaryTabIDs = primary.tabs.map(\.id)
      if let primarySnapshot = panelSnapshots.first {
        primaryTabIDs = restoreShellTabs(
          from: primarySnapshot,
          in: primary,
          existingTabIDs: primaryTabIDs
        )
      }
      restoredTabIDs.append(primaryTabIDs)
    }

    for panelSnapshot in panelSnapshots.dropFirst() {
      guard let session = terminalPanelSession, session.canOpenPanel else { break }
      guard let firstShellTab = panelSnapshot.tabs.first(where: { $0.role == .shell }) else { continue }
      let tab = makeShellTab(
        name: restoredTabName(for: firstShellTab),
        workingDirectory: firstShellTab.workingDirectory
      )
      let anchorPanelID = primaryPanelID ?? panels[0].id
      guard let panel = session.openPanel(
        with: tab,
        beside: anchorPanelID,
        axis: .horizontal
      ) else {
        continue
      }

      var tabIDs = [tab.id]
      if RegularTerminalLaunchFeatures.tabsEnabled {
        tabIDs = restoreShellTabs(
          from: panelSnapshot,
          in: panel,
          existingTabIDs: tabIDs,
          skippingFirstShellTab: true
        )
      }
      restoredPanelIDs.append(panel.id)
      restoredTabIDs.append(tabIDs)
    }

    restoreActiveSelection(
      from: snapshot,
      panelIDs: restoredPanelIDs,
      tabIDs: restoredTabIDs
    )
    refreshWorkspaceRootView()
    syncAppearance(
      isDark: currentIsDark,
      fontSize: currentFontSize,
      fontFamily: currentFontFamily,
      theme: currentTheme
    )
  }

  private func resetToPrimaryTerminal() {
    guard let session = terminalPanelSession,
          let primary = panel(for: primaryPanelID) ?? panels.first else { return }
    let keepTabID = protectedAgentTabID ?? primary.tabs.first?.id
    let closeResult = session.resetToPrimary(keeping: keepTabID)
    for terminal in closeResult.payloads {
      terminateAndUnregister(terminal)
    }
  }

  private func restoreShellTabs(
    from panelSnapshot: TerminalWorkspacePanelSnapshot,
    in panel: RegularTerminalPanel,
    existingTabIDs: [RegularTerminalTabID],
    skippingFirstShellTab: Bool = false
  ) -> [RegularTerminalTabID] {
    guard RegularTerminalLaunchFeatures.tabsEnabled else { return existingTabIDs }
    var restoredTabIDs = existingTabIDs
    var hasSkippedFirstShellTab = false

    for tabSnapshot in panelSnapshot.tabs where tabSnapshot.role == .shell {
      if skippingFirstShellTab && !hasSkippedFirstShellTab {
        hasSkippedFirstShellTab = true
        continue
      }

      let tab = makeShellTab(
        name: restoredTabName(for: tabSnapshot),
        workingDirectory: tabSnapshot.workingDirectory
      )
      panel.appendTab(tab)
      restoredTabIDs.append(tab.id)
    }

    return restoredTabIDs
  }

  private func tabsForWorkspaceSnapshot(
    in panel: RegularTerminalPanel
  ) -> (tabs: [RegularTerminalTab], activeTabIndex: Int) {
    if RegularTerminalLaunchFeatures.tabsEnabled {
      let activeTabIndex = panel.tabs.firstIndex { $0.id == panel.activeTabID } ?? 0
      return (panel.tabs, activeTabIndex)
    }

    if let activeTab = panel.activeTab {
      return ([activeTab], 0)
    }

    if let firstTab = panel.tabs.first {
      return ([firstTab], 0)
    }

    return ([], 0)
  }

  private func restoreActiveSelection(
    from snapshot: TerminalWorkspaceSnapshot,
    panelIDs: [RegularTerminalPanelID],
    tabIDs: [[RegularTerminalTabID]]
  ) {
    guard !panelIDs.isEmpty else { return }
    let panelIndex = min(max(snapshot.activePanelIndex, 0), panelIDs.count - 1)
    let panelID = panelIDs[panelIndex]

    guard let panel = panel(for: panelID) else { return }
    let savedPanel = snapshot.panels.indices.contains(panelIndex) ? snapshot.panels[panelIndex] : nil
    let savedActiveTabIndex = savedPanel?.activeTabIndex ?? 0
    let panelTabIDs = tabIDs.indices.contains(panelIndex) ? tabIDs[panelIndex] : []
    guard !panelTabIDs.isEmpty else { return }

    let tabIndex = min(max(savedActiveTabIndex, 0), panelTabIDs.count - 1)
    _ = terminalPanelSession?.selectTab(panelTabIDs[tabIndex], in: panel.id)
  }

  private func normalizedPanelSnapshots(
    _ panels: [TerminalWorkspacePanelSnapshot]
  ) -> [TerminalWorkspacePanelSnapshot] {
    let primary = panels.first { $0.role == .primary } ?? panels.first
    let auxiliaries = panels.filter { $0.role == .auxiliary }
    return ([primary].compactMap { $0 } + auxiliaries).prefix(4).map { $0 }
  }

  private func restoredTabName(for tab: TerminalWorkspaceTabSnapshot) -> String? {
    if tab.role == .agent {
      return providerDisplayName
    }
    return Self.nonEmpty(tab.name) ?? Self.nonEmpty(tab.title) ?? "Shell"
  }

  private func resolvedExistingDirectory(_ path: String?) -> String {
    guard let path = Self.nonEmpty(path) else { return resolvedProjectPath }
    let expandedPath = (path as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      return resolvedProjectPath
    }
    return expandedPath
  }

  private func panel(for id: RegularTerminalPanelID?) -> RegularTerminalPanel? {
    terminalPanelSession?.panel(for: id)
  }

  private func isProtectedAgentTab(_ tab: RegularTerminalTab) -> Bool {
    guard let located = locate(tab) else { return false }
    return isProtectedAgentTab(tab, in: located.panel.id)
  }

  private func isProtectedAgentTab(_ tab: RegularTerminalTab, in panelID: RegularTerminalPanelID) -> Bool {
    panelID == protectedAgentPanelID && tab.id == protectedAgentTabID
  }

  private func locate(_ tab: RegularTerminalTab) -> (panel: RegularTerminalPanel, tab: RegularTerminalTab)? {
    for panel in panels {
      if let matchedTab = panel.tabs.first(where: { $0.id == tab.id }) {
        return (panel, matchedTab)
      }
    }
    return nil
  }

  private func locate(terminal: TerminalView) -> (panel: RegularTerminalPanel, tab: RegularTerminalTab)? {
    for panel in panels {
      if let matchedTab = panel.tabs.first(where: { $0.terminalView === terminal }) {
        return (panel, matchedTab)
      }
    }
    return nil
  }

  private func focusedTab(in window: NSWindow) -> RegularTerminalTab? {
    guard let responder = window.firstResponder else { return nil }
    guard let responderView = responder as? NSView else { return nil }
    if let focusedTab = allTabs.first(where: { tab in
      responderView === tab.terminalView || responderView.isDescendant(of: tab.terminalView)
    }) {
      return focusedTab
    }
    if responderView === self || responderView.isDescendant(of: self) {
      return activeTab
    }
    return nil
  }

  private func tab(containingMouseEvent event: NSEvent) -> RegularTerminalTab? {
    allTabs.first { tab in
      guard event.window === tab.terminalView.window else { return false }
      let location = tab.terminalView.convert(event.locationInWindow, from: nil)
      return tab.terminalView.bounds.contains(location)
    }
  }

  private func syncSelection(to tab: RegularTerminalTab) {
    guard let located = locate(tab) else { return }
    if activePanelID != located.panel.id || located.panel.activeTabID != located.tab.id {
      _ = terminalPanelSession?.selectTab(located.tab.id, in: located.panel.id)
      refreshWorkspaceRootView()
      notifyWorkspaceChanged()
    }
  }

  private func terminateAndUnregister(_ terminal: SafeLocalProcessTerminalView) {
    let key = ObjectIdentifier(terminal)
    if let pid = terminalPidMap.removeValue(forKey: key) {
      Task {
        await TerminalProcessRegistry.shared.unregister(pid: pid)
      }
    }
    terminal.stopReceivingData()
    terminal.terminateProcessTree()
  }

  private func notifyWorkspaceChanged() {
    guard !isRestoringWorkspace else { return }
    guard let snapshot = captureWorkspaceSnapshot() else { return }
    guard snapshot != lastWorkspaceSnapshot else { return }
    lastWorkspaceSnapshot = snapshot
    onWorkspaceChanged?(snapshot)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  // MARK: - ManagedLocalProcessTerminalViewDelegate

  public func sizeChanged(source: ManagedLocalProcessTerminalView, newCols: Int, newRows: Int) {}

  public func setTerminalTitle(source: ManagedLocalProcessTerminalView, title: String) {
    guard let located = locate(terminal: source) else { return }
    located.tab.title = title
    refreshWorkspaceRootView()
    notifyWorkspaceChanged()
  }

  public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    guard let located = locate(terminal: source) else { return }
    located.tab.workingDirectory = directory
    notifyWorkspaceChanged()
  }

  public func processTerminated(source: TerminalView, exitCode: Int32?) {
    let key = ObjectIdentifier(source)
    if let pid = terminalPidMap[key] {
      Task {
        await TerminalProcessRegistry.shared.unregister(pid: pid)
      }
      terminalPidMap.removeValue(forKey: key)
    }
  }
}

// MARK: - Preview

#Preview("Resume Session") {
  EmbeddedTerminalView(
    terminalKey: "test-session-123",
    sessionId: "test-session-123",
    projectPath: "/Users/test/project",
    cliConfiguration: .claudeDefault
  )
  .frame(width: 600, height: 400)
}

#Preview("New Session") {
  EmbeddedTerminalView(
    terminalKey: "pending-preview",
    projectPath: "/Users/test/project",
    cliConfiguration: .claudeDefault
  )
  .frame(width: 600, height: 400)
}
