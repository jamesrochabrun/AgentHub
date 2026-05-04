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
    nsView.mount(terminal, key: terminalKey)
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
  private var isConfigured = false
  private var hasDeliveredInitialPrompt = false
  private var hasPrefilledInitialInputText = false
  private var lastAppliedFontSize: CGFloat?
  private var lastAppliedFontFamily: String?
  private var lastAppliedIsDark: Bool?
  private var terminalPidMap: [ObjectIdentifier: pid_t] = [:]
  private var localEventMonitor: Any?
  public var onUserInteraction: (() -> Void)?
  public var onRequestShowEditor: (() -> Void)?
  public var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  var terminalSessionKey: String?
  weak var sessionViewModel: CLISessionsViewModel?
  var metadataStore: SessionMetadataStore?
  var terminateProcessCallCount = 0

  /// The PID of the current terminal process, if running
  public var currentProcessPID: Int32? {
    terminalView?.currentProcessId
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
    // Stop data reception FIRST to prevent DispatchIO race condition crash
    terminalView?.stopReceivingData()
    terminalView?.terminateProcessTree()
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
    terminalView?.removeFromSuperview()
    terminalView = nil
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
      provider: SessionProviderKind(cliMode: cliConfiguration.mode),
      sessionId: sessionId,
      projectPath: projectPath,
      expectedExecutable: cliConfiguration.executableName
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

    let terminal = prepareTerminalView(isDark: isDark)
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
  }

  /// Resets the prompt delivery flag so a new prompt can be sent.
  /// Call this before sendPromptIfNeeded when sending a follow-up prompt (e.g., from inline editor).
  public func resetPromptDeliveryFlag() {
    hasDeliveredInitialPrompt = false
  }

  /// Sends a prompt to the terminal (only once per terminal instance unless reset)
  public func sendPromptIfNeeded(_ prompt: String) {
    guard let terminal = terminalView else { return }
    guard !hasDeliveredInitialPrompt else { return }
    hasDeliveredInitialPrompt = true

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
    guard let terminal = terminalView else { return false }
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
    guard let terminal = terminalView else { return }
    terminal.send(txt: text)
  }

  /// Prefills initial terminal input text once, without pressing Enter.
  public func typeInitialTextIfNeeded(_ text: String) {
    guard !text.isEmpty else { return }
    guard !hasPrefilledInitialInputText else { return }
    hasPrefilledInitialInputText = true
    typeText(text)
  }

  public func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String = "SF Mono", theme: RuntimeTheme? = nil) {
    updateColors(isDark: isDark, theme: theme)
    updateFont(size: fontSize, family: fontFamily)
  }

  /// Updates terminal font size and family.
  public func updateFont(size: CGFloat, family: String = "SF Mono") {
    guard let terminal = terminalView else { return }
    let resolvedSize = max(size, 8)
    guard lastAppliedFontSize != resolvedSize || lastAppliedFontFamily != family else { return }

    let font = NSFont(name: family, size: resolvedSize)
      ?? NSFont(name: "SF Mono", size: resolvedSize)
      ?? NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
    terminal.font = font
    lastAppliedFontSize = resolvedSize
    lastAppliedFontFamily = family
  }

  private var lastAppliedThemeId: String?

  /// Updates terminal colors from theme or falls back to default dark/light.
  /// Only background and cursor are themed — foreground and ANSI colors are left
  /// untouched to preserve Claude Code / Codex syntax highlighting.
  public func updateColors(isDark: Bool, theme: RuntimeTheme? = nil) {
    guard let terminal = terminalView else { return }

    let themeId = theme?.id
    let needsUpdate = lastAppliedIsDark != isDark || lastAppliedThemeId != themeId
    guard needsUpdate else { return }

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

    lastAppliedIsDark = isDark
    lastAppliedThemeId = themeId
    terminal.needsDisplay = true
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
      guard let self, let terminal = self.terminalView else { return event }

      switch event.type {
      case .keyDown:
        guard let window = terminal.window,
              event.window === window else { break }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isTerminalVisible = terminal.superview != nil && !terminal.isHidden && terminal.alphaValue > 0

        if isTerminalVisible,
           self.isTerminalResponderActive(window: window, terminal: terminal),
           flags == .control,
           event.keyCode == 50,
           self.onRequestShowEditor != nil {
          self.onRequestShowEditor?()
          self.onUserInteraction?()
          return nil
        }

        // Cmd+F: only when terminal has focus (let file editor handle it otherwise)
        if isTerminalVisible, self.isTerminalResponderActive(window: window, terminal: terminal) {
          if flags == .command, event.charactersIgnoringModifiers == "f" {
            window.makeFirstResponder(terminal)
            // performFindPanelAction requires an NSMenuItem with the correct tag
            let menuItem = NSMenuItem()
            menuItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            terminal.performFindPanelAction(menuItem)
            return nil
          }

          }

        // Typing shortcuts (require terminal to be first responder)
        guard isTerminalResponderActive(window: window, terminal: terminal) else { break }

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
        guard let window = terminal.window, event.window === window else { return event }
        let locationInTerminal = terminal.convert(event.locationInWindow, from: nil)
        if terminal.bounds.contains(locationInTerminal) {
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

    addSubview(terminal)
    NSLayoutConstraint.activate([
      terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
      terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
      terminal.topAnchor.constraint(equalTo: topAnchor),
      terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])

    self.terminalView = terminal
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

  // MARK: - ManagedLocalProcessTerminalViewDelegate

  public func sizeChanged(source: ManagedLocalProcessTerminalView, newCols: Int, newRows: Int) {}

  public func setTerminalTitle(source: ManagedLocalProcessTerminalView, title: String) {}

  public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

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
