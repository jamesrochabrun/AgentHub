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
  }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    guard !isStopped else { return }
    super.dataReceived(slice: slice)
  }
}

// MARK: - EmbeddedTerminalView

/// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView
/// Provides an embedded terminal for interacting with Claude sessions
public struct EmbeddedTerminalView: NSViewRepresentable {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(AgentHubDefaults.terminalFontSize) private var terminalFontSize: Double = 12

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
    self.consumeQueuedWebPreviewContextOnSubmit = consumeQueuedWebPreviewContextOnSubmit
  }

  public func makeNSView(context: Context) -> TerminalContainerView {
    let isDark = colorScheme == .dark

    // Use shared terminal storage if viewModel is provided
    if let viewModel = viewModel {
      let terminalContainer = viewModel.getOrCreateTerminal(
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
      terminalContainer.onUserInteraction = onUserInteraction
      terminalContainer.consumeQueuedWebPreviewContextOnSubmit = consumeQueuedWebPreviewContextOnSubmit
      terminalContainer.terminalSessionKey = terminalKey
      terminalContainer.sessionViewModel = viewModel
      return terminalContainer
    }

    // Fallback: create standalone terminal (for previews)
    let containerView = TerminalContainerView()
    containerView.configure(
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
    containerView.onUserInteraction = onUserInteraction
    containerView.consumeQueuedWebPreviewContextOnSubmit = consumeQueuedWebPreviewContextOnSubmit
    return containerView
  }

  public func updateNSView(_ nsView: TerminalContainerView, context: Context) {
    nsView.onUserInteraction = onUserInteraction
    nsView.consumeQueuedWebPreviewContextOnSubmit = consumeQueuedWebPreviewContextOnSubmit
    nsView.syncAppearance(isDark: colorScheme == .dark, fontSize: CGFloat(terminalFontSize))

    // If there's a pending prompt in the viewModel, send it (and clear it)
    // Use terminalKey (not sessionId) since it works for both pending and real sessions
    if let prompt = viewModel?.pendingPrompt(for: terminalKey) {
      nsView.resetPromptDeliveryFlag()
      nsView.sendPromptIfNeeded(prompt)
      viewModel?.clearPendingPrompt(for: terminalKey)
    }
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
  private var lastAppliedIsDark: Bool?
  private var terminalPidMap: [ObjectIdentifier: pid_t] = [:]
  private var localEventMonitor: Any?
  public var onUserInteraction: (() -> Void)?
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
  func restart(
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

  func configure(
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
    registerProcessIfNeeded(for: terminal)

    if let initialInputText, !initialInputText.isEmpty {
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(300))
        self?.typeInitialTextIfNeeded(initialInputText)
      }
    }
  }

  func configureShell(
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
    registerProcessIfNeeded(for: terminal)
  }

  /// Resets the prompt delivery flag so a new prompt can be sent.
  /// Call this before sendPromptIfNeeded when sending a follow-up prompt (e.g., from inline editor).
  func resetPromptDeliveryFlag() {
    hasDeliveredInitialPrompt = false
  }

  /// Sends a prompt to the terminal (only once per terminal instance unless reset)
  func sendPromptIfNeeded(_ prompt: String) {
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
  func submitPromptImmediately(_ prompt: String) -> Bool {
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

  public func syncAppearance(isDark: Bool, fontSize: CGFloat) {
    updateColors(isDark: isDark)
    updateFont(size: fontSize)
  }

  /// Updates terminal font size.
  public func updateFont(size: CGFloat) {
    guard let terminal = terminalView else { return }
    let resolvedSize = max(size, 8)
    guard lastAppliedFontSize != resolvedSize else { return }

    let font = NSFont(name: "SF Mono", size: resolvedSize)
      ?? NSFont(name: "Menlo", size: resolvedSize)
      ?? NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
    terminal.font = font
    lastAppliedFontSize = resolvedSize
  }

  /// Updates terminal colors based on color scheme.
  /// Called when the app's color scheme changes.
  public func updateColors(isDark: Bool) {
    guard let terminal = terminalView else { return }
    guard lastAppliedIsDark != isDark else { return }

    if isDark {
      terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)
    } else {
      terminal.nativeBackgroundColor = NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    }

    lastAppliedIsDark = isDark
    terminal.needsDisplay = true
  }

  private func applyInitialAppearance(to terminal: TerminalView, isDark: Bool) {
    let fontSize: CGFloat = 12
    lastAppliedFontSize = fontSize
    let font = NSFont(name: "SF Mono", size: fontSize)
      ?? NSFont(name: "Menlo", size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    terminal.font = font

    if isDark {
      terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
      terminal.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.88, alpha: 1.0)
    } else {
      terminal.nativeBackgroundColor = NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)
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

        // Terminal-wide shortcuts (work when terminal is visible, even without focus)
        if isTerminalVisible {
          // Cmd+F: activate SwiftTerm's built-in search/find bar
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
    // Find the CLI executable using just the executable name (first word of command)
    let command = cliConfiguration.command
    let additionalPaths = cliConfiguration.additionalPaths

    let executablePath: String?
    switch cliConfiguration.mode {
    case .codex:
      executablePath = TerminalLauncher.findCodexExecutable(
        command: cliConfiguration.executableName,
        additionalPaths: additionalPaths
      )
    case .claude:
      executablePath = TerminalLauncher.findExecutable(
        command: cliConfiguration.executableName,
        additionalPaths: additionalPaths
      )
    }

    guard let executablePath else {
      // Show error in terminal
      terminal.feed(text: "\r\n\u{001B}[31mError: Could not find '\(command)' command.\u{001B}[0m\r\n")
      terminal.feed(text: "Please ensure the CLI is installed.\r\n")
      return
    }

    let environment = makeProcessEnvironment(additionalPaths: additionalPaths)

    // Build the shell command with working directory
    // Since SwiftTerm's Mac API doesn't support currentDirectory directly,
    // we use bash -c to cd first then run claude
    let workingDirectory = projectPath.isEmpty ? NSHomeDirectory() : projectPath
    let escapedPath = workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
    let escapedCLIPath = executablePath.replacingOccurrences(of: "'", with: "'\\''")
#if DEBUG
    let homeEnv = environment["HOME"] ?? "<nil>"
    AppLogger.session.debug(
      "[ClaudeProcess] workingDirectory=\(workingDirectory, privacy: .public) homeEnv=\(homeEnv, privacy: .public) command=\(command, privacy: .public)"
    )
#endif

    // Read AI configuration defaults for this provider from SQLite
    let aiConfig = metadataStore?.getAIConfigSync(for: cliConfiguration.mode.rawValue)
    let allowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.allowedTools)
    let disallowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.disallowedTools)

    // Build command: resume existing session or start new session
    let args = cliConfiguration.argumentsForSession(
      sessionId: sessionId,
      prompt: initialPrompt,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      worktreeName: worktreeName,
      permissionModePlan: permissionModePlan,
      model: aiConfig?.defaultModel,
      effortLevel: aiConfig?.effortLevel,
      allowedTools: allowedTools.isEmpty ? nil : allowedTools,
      disallowedTools: disallowedTools.isEmpty ? nil : disallowedTools,
      codexApprovalPolicy: aiConfig?.approvalPolicy
    )
    let escapedArgs = args.map { $0.replacingOccurrences(of: "'", with: "'\\''") }
    let joinedArgs = escapedArgs.map { "'\($0)'" }.joined(separator: " ")
    let shellCommand = joinedArgs.isEmpty
      ? "cd '\(escapedPath)' && exec '\(escapedCLIPath)'"
      : "cd '\(escapedPath)' && exec '\(escapedCLIPath)' \(joinedArgs)"

    // Start bash with the command
    terminal.startProcess(
      executable: "/bin/bash",
      args: ["-c", shellCommand],
      environment: environment.map { "\($0.key)=\($0.value)" }
    )
  }

  private func startShellProcess(
    terminal: ManagedLocalProcessTerminalView,
    projectPath: String,
    shellPath: String? = nil
  ) {
    let environment = makeProcessEnvironment(additionalPaths: [])
    let shellExecutable = resolveShellExecutablePath(shellPath)
    let escapedPath = shellEscape(projectPath.isEmpty ? NSHomeDirectory() : projectPath)
    let escapedShellPath = shellEscape(shellExecutable)
    let shellCommand = "cd '\(escapedPath)' && exec '\(escapedShellPath)' -l"

    terminal.startProcess(
      executable: "/bin/bash",
      args: ["-c", shellCommand],
      environment: environment.map { "\($0.key)=\($0.value)" }
    )
  }

  private func makeProcessEnvironment(additionalPaths: [String]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    environment["TERM_PROGRAM"] = "SwiftTerm"

    let paths = CLIPathResolver.executableSearchPaths(additionalPaths: additionalPaths)
    let pathString = paths.joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }
    return environment
  }

  private func resolveShellExecutablePath(_ shellPath: String?) -> String {
    let candidate = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    return "/bin/zsh"
  }

  private func shellEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
  }

  private func registerProcessIfNeeded(for terminal: SafeLocalProcessTerminalView) {
    guard let pid = terminal.currentProcessId, pid > 0 else { return }
    let key = ObjectIdentifier(terminal)
    terminalPidMap[key] = pid
    TerminalProcessRegistry.shared.register(pid: pid)
  }

  // MARK: - ManagedLocalProcessTerminalViewDelegate

  public func sizeChanged(source: ManagedLocalProcessTerminalView, newCols: Int, newRows: Int) {}

  public func setTerminalTitle(source: ManagedLocalProcessTerminalView, title: String) {}

  public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  public func processTerminated(source: TerminalView, exitCode: Int32?) {
    let key = ObjectIdentifier(source)
    if let pid = terminalPidMap[key] {
      TerminalProcessRegistry.shared.unregister(pid: pid)
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
