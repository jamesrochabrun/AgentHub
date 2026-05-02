//
//  TerminalContainerView.swift
//  AgentHub
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

// MARK: - TerminalContainerView

/// Container view that manages the terminal lifecycle
public class TerminalContainerView: NSView, ManagedLocalProcessTerminalViewDelegate {
  fileprivate final class WorkspaceTab {
    let id: UUID
    let role: TerminalWorkspaceTabRole
    var name: String?
    var title: String?
    var workingDirectory: String?
    var activity: RegularTerminalPaneActivity?
    let terminal: SafeLocalProcessTerminalView

    init(
      id: UUID = UUID(),
      role: TerminalWorkspaceTabRole,
      name: String?,
      title: String?,
      workingDirectory: String?,
      activity: RegularTerminalPaneActivity? = nil,
      terminal: SafeLocalProcessTerminalView
    ) {
      self.id = id
      self.role = role
      self.name = name
      self.title = title
      self.workingDirectory = workingDirectory
      self.activity = activity
      self.terminal = terminal
    }
  }

  fileprivate final class WorkspacePane {
    let id: UUID
    var role: TerminalWorkspacePanelRole
    var tabs: [WorkspaceTab]
    var activeTabID: UUID
    var activity: RegularTerminalPaneActivity?

    init(
      id: UUID = UUID(),
      role: TerminalWorkspacePanelRole,
      tabs: [WorkspaceTab],
      activeTabID: UUID? = nil,
      activity: RegularTerminalPaneActivity? = nil
    ) {
      self.id = id
      self.role = role
      self.tabs = tabs
      self.activeTabID = activeTabID ?? tabs.first?.id ?? UUID()
      self.activity = activity
    }

    var activeTab: WorkspaceTab? {
      tabs.first { $0.id == activeTabID } ?? tabs.first
    }
  }

  fileprivate indirect enum WorkspaceLayoutNode: Equatable {
    case pane(UUID)
    case split(axis: TerminalWorkspaceSplitAxis, children: [WorkspaceLayoutNode])
  }

  private enum WorkspaceMode {
    case cli
    case shell
  }

  private static let maxPaneCount = 4
  private static let paneDividerSpacing: CGFloat = 1
  private static let paneHeaderHeight: CGFloat = 28
  private static let shellStartupFallbackDelay: Duration = .milliseconds(900)
  private static let closeActivityDelay: Duration = .milliseconds(140)

  private var isConfigured = false
  private var hasDeliveredInitialPrompt = false
  private var hasPrefilledInitialInputText = false
  private var lastAppliedFontSize: CGFloat?
  private var lastAppliedFontFamily: String?
  private var lastAppliedIsDark: Bool?
  private var lastAppliedThemeId: String?
  private var currentIsDark = true
  private var currentFontSize: CGFloat = 12
  private var currentFontFamily = "SF Mono"
  private var currentTheme: TerminalAppearanceTheme?
  private var configuredProjectPath = ""
  private var workspaceMode: WorkspaceMode?
  private var panes: [WorkspacePane] = []
  private var layoutNode: WorkspaceLayoutNode?
  private var activePaneID: UUID?
  private var protectedAgentPaneID: UUID?
  private var protectedAgentTabID: UUID?
  private var rootWorkspaceView: TerminalSplitContainerView?
  private var paneHeaderViews: [UUID: NSHostingView<RegularTerminalPaneHeader>] = [:]
  private var paneContainerViews: [UUID: RegularTerminalPaneContainerView] = [:]
  private var paneActiveTabIDs: [UUID: UUID] = [:]
  private var tabActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var paneActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var pendingWorkspaceSnapshot: TerminalWorkspaceSnapshot?
  private var isRestoringWorkspace = false
  private var lastWorkspaceSnapshot: TerminalWorkspaceSnapshot?
  private var terminatedWorkspaceTabCount = 0
  private var terminalPidMap: [ObjectIdentifier: pid_t] = [:]
  private var localEventMonitor: Any?
  public var onUserInteraction: (() -> Void)?
  public var onRequestShowEditor: (() -> Void)?
  public var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  public var onOpenFile: ((String, Int?) -> Void)?
  var terminalSessionKey: String?
  var terminateProcessCallCount = 0
  var startsTerminalProcesses = true

  var terminalView: SafeLocalProcessTerminalView? {
    activeTab?.terminal
  }

  /// The PID of the current terminal process, if running
  public var currentProcessPID: Int32? {
    protectedAgentTab?.terminal.currentProcessId ?? activeTab?.terminal.currentProcessId
  }

  // MARK: - Lifecycle

  /// Terminate process on deallocation (safety net)
  deinit {
    cancelAllActivityTasks()
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
    for tab in allTabs() {
      terminate(tab)
    }
  }

  // MARK: - Configuration

  /// Restarts the terminal by terminating the current process and starting a new one.
  /// Use this to reload session history after external changes.
  public func restart(
    launch: Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError>,
    projectPath: String
  ) {
    terminateProcess()
    resetWorkspace()
    isConfigured = false
    hasDeliveredInitialPrompt = false  // Reset for fresh start
    hasPrefilledInitialInputText = false
    configure(
      launch: launch,
      projectPath: projectPath,
      initialInputText: nil,
      isDark: currentIsDark
    )
  }

  public func configure(
    launch: Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError>,
    projectPath: String,
    initialInputText: String? = nil,
    isDark: Bool = true
  ) {
    guard !isConfigured else { return }
    isConfigured = true
    workspaceMode = .cli
    configuredProjectPath = projectPath
    currentIsDark = isDark

    let terminal = makeTerminalView(isDark: isDark)
    let primaryTab = WorkspaceTab(
      role: .agent,
      name: "Agent",
      title: nil,
      workingDirectory: resolvedProjectPath,
      terminal: terminal
    )
    let primaryPane = WorkspacePane(role: .primary, tabs: [primaryTab])
    panes = [primaryPane]
    layoutNode = .pane(primaryPane.id)
    activePaneID = primaryPane.id
    protectedAgentPaneID = primaryPane.id
    protectedAgentTabID = primaryTab.id

    installInteractionMonitorIfNeeded()
    rebuildWorkspaceViews()

    startCLIProcess(
      terminal: terminal,
      launch: launch
    )
    registerProcessIfNeeded(for: terminal)

    if let initialInputText, !initialInputText.isEmpty {
      terminal.onProcessReady = { [weak self] in
        self?.typeInitialTextIfNeeded(initialInputText)
      }
    }

    restorePendingWorkspaceSnapshotIfNeeded()
    lastWorkspaceSnapshot = captureWorkspaceSnapshot()
  }

  public func configureShell(
    launch: EmbeddedTerminalLaunch,
    projectPath: String,
    isDark: Bool = true
  ) {
    guard !isConfigured else { return }
    isConfigured = true
    workspaceMode = .shell
    configuredProjectPath = projectPath
    currentIsDark = isDark

    let terminal = makeTerminalView(isDark: isDark)
    let primaryTab = WorkspaceTab(
      role: .shell,
      name: "Shell",
      title: nil,
      workingDirectory: resolvedProjectPath,
      terminal: terminal
    )
    let primaryPane = WorkspacePane(role: .primary, tabs: [primaryTab])
    panes = [primaryPane]
    layoutNode = .pane(primaryPane.id)
    activePaneID = primaryPane.id

    installInteractionMonitorIfNeeded()
    rebuildWorkspaceViews()

    startShellProcess(
      terminal: terminal,
      launch: launch
    )
    registerProcessIfNeeded(for: terminal)

    restorePendingWorkspaceSnapshotIfNeeded()
    lastWorkspaceSnapshot = captureWorkspaceSnapshot()
  }

  /// Resets the prompt delivery flag so a new prompt can be sent.
  /// Call this before sendPromptIfNeeded when sending a follow-up prompt (e.g., from inline editor).
  public func resetPromptDeliveryFlag() {
    hasDeliveredInitialPrompt = false
  }

  /// Sends a prompt to the terminal (only once per terminal instance unless reset)
  public func sendPromptIfNeeded(_ prompt: String) {
    guard let terminal = promptTargetTerminal else { return }
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
    guard let terminal = promptTargetTerminal else { return false }
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
    guard let terminal = activeTab?.terminal ?? promptTargetTerminal else { return }
    terminal.send(txt: text)
  }

  /// Prefills initial terminal input text once, without pressing Enter.
  public func typeInitialTextIfNeeded(_ text: String) {
    guard !text.isEmpty else { return }
    guard !hasPrefilledInitialInputText else { return }
    hasPrefilledInitialInputText = true
    promptTargetTerminal?.send(txt: text)
  }

  public func syncAppearance(
    isDark: Bool,
    fontSize: CGFloat,
    fontFamily: String = "SF Mono",
    theme: TerminalAppearanceTheme? = nil
  ) {
    currentIsDark = isDark
    currentFontSize = fontSize
    currentFontFamily = fontFamily
    currentTheme = theme
    updateColors(isDark: isDark, theme: theme)
    updateFont(size: fontSize, family: fontFamily)
  }

  /// Updates terminal font size and family.
  public func updateFont(size: CGFloat, family: String = "SF Mono") {
    let resolvedSize = max(size, 8)
    guard lastAppliedFontSize != resolvedSize || lastAppliedFontFamily != family else { return }

    let font = NSFont(name: family, size: resolvedSize)
      ?? NSFont(name: "SF Mono", size: resolvedSize)
      ?? NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
    for terminal in allTerminalViews() {
      terminal.font = font
    }
    lastAppliedFontSize = resolvedSize
    lastAppliedFontFamily = family
  }

  /// Updates terminal colors from theme or falls back to default dark/light.
  /// Only background and cursor are themed — foreground and ANSI colors are left
  /// untouched to preserve Claude Code / Codex syntax highlighting.
  public func updateColors(isDark: Bool, theme: TerminalAppearanceTheme? = nil) {
    let themeId = theme?.id
    let needsUpdate = lastAppliedIsDark != isDark || lastAppliedThemeId != themeId
    guard needsUpdate else { return }

    for terminal in allTerminalViews() {
      applyColors(to: terminal, isDark: isDark, theme: theme)
      terminal.needsDisplay = true
    }

    lastAppliedIsDark = isDark
    lastAppliedThemeId = themeId
  }

  private func applyInitialAppearance(to terminal: TerminalView, isDark: Bool) {
    let fontSize: CGFloat = 12
    let font = NSFont(name: "SF Mono", size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    terminal.font = font

    applyColors(to: terminal, isDark: isDark, theme: currentTheme)
  }

  private func installInteractionMonitorIfNeeded() {
    guard localEventMonitor == nil else { return }
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
      guard let self else { return event }

      switch event.type {
      case .keyDown:
        guard let window = event.window ?? self.window, window === self.window else { break }
        guard let terminal = self.focusedTerminal(in: window) else { break }

        self.syncActiveSelection(to: terminal)

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "t" {
          self.openShellTab()
          self.onUserInteraction?()
          return nil
        }

        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
          self.openShellPane(axis: .vertical)
          self.onUserInteraction?()
          return nil
        }

        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
          self.openShellPane(axis: .horizontal)
          self.onUserInteraction?()
          return nil
        }

        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "w" {
          self.closeActiveShellTabOrPane()
          self.onUserInteraction?()
          return nil
        }

        if flags == [.command, .shift], event.keyCode == 123 {
          self.selectAdjacentTab(direction: -1)
          self.onUserInteraction?()
          return nil
        }

        if flags == [.command, .shift], event.keyCode == 124 {
          self.selectAdjacentTab(direction: 1)
          self.onUserInteraction?()
          return nil
        }

        if flags == .command, event.keyCode == 123 {
          self.focusAdjacentPane(delta: -1)
          self.onUserInteraction?()
          return nil
        }

        if flags == .command, event.keyCode == 124 {
          self.focusAdjacentPane(delta: 1)
          self.onUserInteraction?()
          return nil
        }

        guard let window = terminal.window,
              event.window === window else { break }

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
        guard isProtectedAgentTerminal(terminal) else {
          self.onUserInteraction?()
          break
        }

        let shortcut = NewlineShortcut(
          rawValue: UserDefaults.standard.integer(forKey: TerminalUserDefaultsKeys.terminalNewlineShortcut)
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
        guard let terminal = self.terminal(containingMouseEvent: event) else { return event }
        self.syncActiveSelection(to: terminal)
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

  private func makeTerminalView(isDark: Bool) -> SafeLocalProcessTerminalView {
    // Use a sensible fallback frame when bounds is zero (view not yet laid out by SwiftUI).
    // SwiftTerm calculates column/row count from the initial frame — a zero frame produces a
    // ~2-column terminal that wraps every character. Auto Layout will correct the size on the
    // next layout pass and SwiftTerm's setFrameSize override sends SIGWINCH to the process.
    let initialFrame = bounds.isEmpty ? CGRect(x: 0, y: 0, width: 800, height: 600) : bounds
    let terminal = SafeLocalProcessTerminalView(frame: initialFrame)
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminal.processDelegate = self
    terminal.projectPath = configuredProjectPath
    terminal.onOpenFile = { [weak self] path, line in
      self?.onOpenFile?(path, line)
    }

    configureTerminalAppearance(terminal, isDark: isDark)
    terminal.font = resolvedFont()
    applyColors(to: terminal, isDark: currentIsDark, theme: currentTheme)
    return terminal
  }

  private func startCLIProcess(
    terminal: ManagedLocalProcessTerminalView,
    launch: Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError>
  ) {
    guard case .success(let launch) = launch else {
      let message: String
      if case .failure(let error) = launch {
        message = error.localizedDescription
      } else {
        message = "Could not start terminal process."
      }
      terminal.feed(text: "\r\n\u{001B}[31mError: \(message)\u{001B}[0m\r\n")
      terminal.feed(text: "Please ensure the CLI is installed.\r\n")
      return
    }

#if DEBUG
    let homeEnv = launch.environment["HOME"] ?? "<nil>"
    TerminalUILogger.terminal.debug("[TerminalProcess] homeEnv=\(homeEnv, privacy: .public)")
#endif

    guard startsTerminalProcesses else { return }

    terminal.startProcess(
      executable: launch.swiftTermExecutable,
      args: launch.swiftTermArguments,
      environment: launch.swiftTermEnvironment
    )
  }

  private func startShellProcess(
    terminal: ManagedLocalProcessTerminalView,
    launch: EmbeddedTerminalLaunch
  ) {
    guard startsTerminalProcesses else { return }

    terminal.startProcess(
      executable: launch.swiftTermExecutable,
      args: launch.swiftTermArguments,
      environment: launch.swiftTermEnvironment
    )
  }

  private func registerProcessIfNeeded(for terminal: SafeLocalProcessTerminalView) {
    guard let pid = terminal.currentProcessId, pid > 0 else { return }
    let key = ObjectIdentifier(terminal)
    terminalPidMap[key] = pid
    TerminalProcessRegistry.shared.register(pid: pid)
  }

  // MARK: - ManagedLocalProcessTerminalViewDelegate

  public func sizeChanged(source: ManagedLocalProcessTerminalView, newCols: Int, newRows: Int) {}

  public func setTerminalTitle(source: ManagedLocalProcessTerminalView, title: String) {
    guard let (pane, tab) = paneAndTab(for: source) else { return }
    tab.title = Self.nonEmpty(title)
    updatePaneHeader(for: pane.id)
    notifyWorkspaceChanged()
  }

  public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    guard let tab = tab(for: source) else { return }
    tab.workingDirectory = Self.nonEmpty(directory) ?? tab.workingDirectory
    notifyWorkspaceChanged()
  }

  public func processTerminated(source: TerminalView, exitCode: Int32?) {
    let key = ObjectIdentifier(source)
    if let pid = terminalPidMap[key] {
      TerminalProcessRegistry.shared.unregister(pid: pid)
      terminalPidMap.removeValue(forKey: key)
    }
  }

  // MARK: - Workspace Snapshots

  public func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? {
    guard !panes.isEmpty else { return nil }

    let panels = panes.map { pane in
      TerminalWorkspacePanelSnapshot(
        role: pane.role,
        tabs: pane.tabs.map { tab in
          TerminalWorkspaceTabSnapshot(
            role: tab.role,
            name: tab.name,
            title: tab.title,
            workingDirectory: tab.workingDirectory
          )
        },
        activeTabIndex: pane.tabs.firstIndex { $0.id == pane.activeTabID } ?? 0
      )
    }

    let indexByPaneID = Dictionary(uniqueKeysWithValues: panes.enumerated().map { ($0.element.id, $0.offset) })
    return TerminalWorkspaceSnapshot(
      schemaVersion: 2,
      panels: panels,
      activePanelIndex: panes.firstIndex { $0.id == activePaneID } ?? 0,
      layout: layoutNode?.snapshot(indexByPaneID: indexByPaneID)
    )
  }

  public func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) {
    guard isConfigured else {
      pendingWorkspaceSnapshot = snapshot
      return
    }
    guard !snapshot.panels.isEmpty else { return }

    isRestoringWorkspace = true
    defer {
      isRestoringWorkspace = false
      lastWorkspaceSnapshot = captureWorkspaceSnapshot()
    }

    resetToPrimaryPaneForRestore()

    let panelSnapshots = normalizedPanelSnapshots(snapshot.panels)
    var restoredPaneIDs: [UUID] = []

    if let primaryPane = panes.first, let primarySnapshot = panelSnapshots.first {
      primaryPane.role = .primary
      restoreTabs(from: primarySnapshot, in: primaryPane, isPrimaryPane: true)
      restoredPaneIDs.append(primaryPane.id)
    }

    for panelSnapshot in panelSnapshots.dropFirst() {
      guard panes.count < Self.maxPaneCount else { break }
      guard let firstShellTab = panelSnapshot.tabs.first(where: { $0.role == .shell }) else { continue }
      let pane = makeShellPane(from: firstShellTab)
      panes.append(pane)
      if let tab = pane.tabs.first {
        startShellProcess(
          terminal: tab.terminal,
          launch: EmbeddedTerminalLaunch.shellLaunch(projectPath: tab.workingDirectory ?? resolvedProjectPath)
        )
        registerProcessIfNeeded(for: tab.terminal)
      }
      restoreTabs(from: panelSnapshot, in: pane, isPrimaryPane: false, skippingFirstShellTab: true)
      restoredPaneIDs.append(pane.id)
    }

    layoutNode = snapshot.layout.flatMap { layout(from: $0, paneIDs: restoredPaneIDs) }
      ?? flatLayout(for: restoredPaneIDs, axis: .vertical)
    restoreActiveSelection(from: snapshot, paneIDs: restoredPaneIDs)
    rebuildWorkspaceViews()
  }

  // MARK: - Workspace Actions

  private func openShellTab() {
    guard let pane = activePane else { return }
    openShellTab(in: pane)
  }

  private func openShellTab(in pane: WorkspacePane, from snapshot: TerminalWorkspaceTabSnapshot? = nil) {
    let workingDirectory = resolvedDirectoryForNewShell(snapshot?.workingDirectory ?? pane.activeTab?.workingDirectory)
    let tab = makeShellTab(
      name: Self.nonEmpty(snapshot?.name) ?? "Shell",
      title: Self.nonEmpty(snapshot?.title),
      workingDirectory: workingDirectory
    )
    pane.tabs.append(tab)
    pane.activeTabID = tab.id
    activePaneID = pane.id
    prepareShellTabForStartup(tab)
    rebuildWorkspaceViews()
    layoutSubtreeIfNeeded()
    startShellProcess(
      terminal: tab.terminal,
      launch: EmbeddedTerminalLaunch.shellLaunch(projectPath: workingDirectory)
    )
    registerProcessIfNeeded(for: tab.terminal)
    notifyWorkspaceChanged()
    focus()
  }

  private func openShellPane(axis: TerminalWorkspaceSplitAxis) {
    guard panes.count < Self.maxPaneCount, let activePaneID else { return }

    let workingDirectory = resolvedDirectoryForNewShell(activePane?.activeTab?.workingDirectory)
    let pane = makeShellPane(
      from: TerminalWorkspaceTabSnapshot(role: .shell, name: "Shell", workingDirectory: workingDirectory)
    )
    panes.append(pane)
    if let tab = pane.tabs.first {
      prepareShellTabForStartup(tab)
    }
    layoutNode = layoutNode?.replacingPane(activePaneID, withSplitAxis: axis, newPaneID: pane.id)
      ?? flatLayout(for: panes.map(\.id), axis: axis)
    self.activePaneID = pane.id
    rebuildWorkspaceViews()
    layoutSubtreeIfNeeded()
    startShellProcess(
      terminal: pane.tabs[0].terminal,
      launch: EmbeddedTerminalLaunch.shellLaunch(projectPath: workingDirectory)
    )
    registerProcessIfNeeded(for: pane.tabs[0].terminal)
    notifyWorkspaceChanged()
    focus()
  }

  private func selectTab(_ tabID: UUID, in paneID: UUID) {
    guard let pane = pane(for: paneID),
          pane.activity == nil,
          pane.tabs.contains(where: { $0.id == tabID && $0.activity != .closing })
    else { return }
    pane.activeTabID = tabID
    activePaneID = paneID
    rebuildWorkspaceViews()
    notifyWorkspaceChanged()
    focus()
  }

  private func closeTab(_ tabID: UUID, in paneID: UUID) {
    guard let pane = pane(for: paneID),
          let index = pane.tabs.firstIndex(where: { $0.id == tabID }),
          canCloseTab(pane.tabs[index], in: pane)
    else {
      return
    }

    if pane.tabs.count == 1 {
      closeLastTabAndPane(tabIndex: index, in: pane)
      return
    }

    let tab = pane.tabs.remove(at: index)
    terminate(tab)

    if pane.activeTabID == tabID {
      pane.activeTabID = pane.tabs[min(index, pane.tabs.count - 1)].id
    }
    activePaneID = pane.id
    rebuildWorkspaceViews()
    notifyWorkspaceChanged()
  }

  private func requestCloseTab(_ tabID: UUID, in paneID: UUID) {
    guard let pane = pane(for: paneID),
          pane.activity == nil,
          let index = pane.tabs.firstIndex(where: { $0.id == tabID }),
          canCloseTab(pane.tabs[index], in: pane)
    else {
      return
    }

    if pane.tabs.count == 1 {
      requestClosePane(pane)
      return
    }

    let tab = pane.tabs[index]
    guard tab.activity != .closing else { return }
    tab.activity = .closing
    refreshWorkspaceActivityPresentation(focusing: false)

    tabActivityTasks[tabID]?.cancel()
    tabActivityTasks[tabID] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.closeActivityDelay)
      guard !Task.isCancelled else { return }
      self?.tabActivityTasks[tabID] = nil
      self?.closeTab(tabID, in: paneID)
    }
  }

  private func closePane(_ pane: WorkspacePane) {
    guard canClosePane(pane) else { return }
    paneActivityTasks.removeValue(forKey: pane.id)?.cancel()

    for tab in pane.tabs {
      terminate(tab)
    }
    panes.removeAll { $0.id == pane.id }
    layoutNode = layoutNode?.removingPane(pane.id)
    if activePaneID == pane.id {
      activePaneID = firstPaneID(in: layoutNode) ?? panes.first?.id
    }
    rebuildWorkspaceViews()
    notifyWorkspaceChanged()
  }

  private func requestClosePane(_ pane: WorkspacePane) {
    guard canClosePane(pane), pane.activity != .closing else { return }
    pane.activity = .closing
    for tab in pane.tabs {
      tab.activity = .closing
    }
    refreshWorkspaceActivityPresentation(focusing: false)

    let paneID = pane.id
    paneActivityTasks[paneID]?.cancel()
    paneActivityTasks[paneID] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.closeActivityDelay)
      guard !Task.isCancelled else { return }
      self?.paneActivityTasks[paneID] = nil
      guard let pane = self?.pane(for: paneID) else { return }
      self?.closePane(pane)
    }
  }

  private func closeLastTabAndPane(tabIndex: Int, in pane: WorkspacePane) {
    guard pane.tabs.indices.contains(tabIndex), canClosePane(pane) else { return }
    let paneID = pane.id

    let tab = pane.tabs.remove(at: tabIndex)
    terminate(tab)
    panes.removeAll { $0.id == paneID }
    layoutNode = layoutNode?.removingPane(paneID)
    if activePaneID == paneID {
      activePaneID = firstPaneID(in: layoutNode) ?? panes.first?.id
    }
    rebuildWorkspaceViews()
    notifyWorkspaceChanged()
  }

  private func closeActiveShellTabOrPane() {
    guard let pane = activePane, let tab = pane.activeTab else { return }
    if canCloseTab(tab, in: pane) {
      requestCloseTab(tab.id, in: pane.id)
    } else if canClosePane(pane) {
      requestClosePane(pane)
    }
  }

  private func selectAdjacentTab(direction: Int) {
    guard let pane = activePane, !pane.tabs.isEmpty else { return }
    let currentIndex = pane.tabs.firstIndex { $0.id == pane.activeTabID } ?? 0
    let nextIndex = (currentIndex + direction + pane.tabs.count) % pane.tabs.count
    selectTab(pane.tabs[nextIndex].id, in: pane.id)
  }

  private func focusAdjacentPane(delta: Int) {
    guard !panes.isEmpty else { return }
    let currentIndex = panes.firstIndex { $0.id == activePaneID } ?? 0
    let nextIndex = (currentIndex + delta + panes.count) % panes.count
    activePaneID = panes[nextIndex].id
    updateAllPaneHeaders()
    notifyWorkspaceChanged()
    focus()
  }

  // MARK: - Workspace View Tree

  private func rebuildWorkspaceViews() {
    guard let layoutNode,
          let splitTree = splitTree(from: layoutNode) else {
      rootWorkspaceView?.removeFromSuperview()
      rootWorkspaceView = nil
      paneHeaderViews.removeAll()
      paneContainerViews.removeAll()
      paneActiveTabIDs.removeAll()
      return
    }

    let paneIDs = Set(splitTree.paneIDs)
    removeStalePaneViews(keeping: paneIDs)

    let paneViews = Dictionary(
      uniqueKeysWithValues: splitTree.paneIDs.compactMap { paneID -> (UUID, NSView)? in
        guard pane(for: paneID) != nil else { return nil }
        return (paneID, makePaneView(for: paneID))
      }
    )

    if let rootWorkspaceView {
      rootWorkspaceView.update(tree: splitTree, paneViews: paneViews)
    } else {
      let rootView = TerminalSplitContainerView(
        tree: splitTree,
        dividerSize: Self.paneDividerSpacing,
        paneViews: paneViews
      )
      rootView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(rootView)
      NSLayoutConstraint.activate([
        rootView.leadingAnchor.constraint(equalTo: leadingAnchor),
        rootView.trailingAnchor.constraint(equalTo: trailingAnchor),
        rootView.topAnchor.constraint(equalTo: topAnchor),
        rootView.bottomAnchor.constraint(equalTo: bottomAnchor)
      ])
      rootWorkspaceView = rootView
    }
  }

  private func splitTree(from node: WorkspaceLayoutNode) -> TerminalSplitLayoutTree<UUID>? {
    switch node {
    case .pane(let paneID):
      return pane(for: paneID) == nil ? nil : .pane(paneID)
    case .split(let axis, let children):
      let childTrees = children.compactMap(splitTree)
      switch childTrees.count {
      case 0: return nil
      case 1: return childTrees[0]
      default: return .split(axis: axis, children: childTrees)
      }
    }
  }

  private func makePaneView(for paneID: UUID) -> NSView {
    guard let pane = pane(for: paneID), let tab = pane.activeTab else {
      return NSView()
    }

    if let container = paneContainerViews[pane.id], paneActiveTabIDs[pane.id] == tab.id {
      updatePaneActivityPresentation(for: pane.id)
      return container
    }

    paneContainerViews[pane.id]?.removeFromSuperview()
    paneHeaderViews[pane.id] = nil

    let header = NSHostingView(rootView: paneHeader(for: pane))
    paneHeaderViews[pane.id] = header

    let terminal = tab.terminal
    terminal.removeFromSuperview()
    let activity = pane.activity ?? tab.activity
    let activityOverlayView = activity.map {
      RegularTerminalPaneActivityOverlayHostingView(rootView: RegularTerminalPaneActivityOverlay(activity: $0))
    }
    let container = RegularTerminalPaneContainerView(
      headerView: header,
      terminalView: terminal,
      activityOverlayView: activityOverlayView,
      headerHeight: Self.paneHeaderHeight,
      initialSize: fallbackPaneSize()
    )
    paneContainerViews[pane.id] = container
    paneActiveTabIDs[pane.id] = tab.id
    return container
  }

  private func removeStalePaneViews(keeping paneIDs: Set<UUID>) {
    let stalePaneIDs = Set(paneContainerViews.keys).subtracting(paneIDs)
    for paneID in stalePaneIDs {
      paneContainerViews[paneID]?.removeFromSuperview()
      paneContainerViews[paneID] = nil
      paneHeaderViews[paneID] = nil
      paneActiveTabIDs[paneID] = nil
    }
  }

  private func fallbackPaneSize() -> CGSize {
    guard bounds.width > 0, bounds.height > Self.paneHeaderHeight else {
      return CGSize(width: 800, height: 600)
    }
    return bounds.size
  }

  private func headerState(for pane: WorkspacePane) -> RegularTerminalPaneHeaderState {
    RegularTerminalPaneHeaderState(
      tabs: pane.tabs.map { tab in
        RegularTerminalPaneHeaderTabState(
          id: tab.id,
          title: displayTitle(for: tab),
          isActive: tab.id == pane.activeTabID,
          isCloseable: canCloseTab(tab, in: pane) && tab.activity != .closing,
          activity: tab.activity
        )
      },
      canSplit: panes.count < Self.maxPaneCount,
      canClosePane: canClosePane(pane),
      isActivePane: pane.id == activePaneID,
      activity: pane.activity
    )
  }

  private func paneHeader(for pane: WorkspacePane) -> RegularTerminalPaneHeader {
    let paneID = pane.id
    return RegularTerminalPaneHeader(
      state: headerState(for: pane),
      onSelectTab: { [weak self] tabID in self?.selectTab(tabID, in: paneID) },
      onCloseTab: { [weak self] tabID in self?.requestCloseTab(tabID, in: paneID) },
      onNewTab: { [weak self] in
        guard let pane = self?.pane(for: paneID) else { return }
        self?.openShellTab(in: pane)
      },
      onSplitVertical: { [weak self] in self?.splitFromPane(paneID, axis: .vertical) },
      onSplitHorizontal: { [weak self] in self?.splitFromPane(paneID, axis: .horizontal) },
      onClosePane: { [weak self] in
        guard let pane = self?.pane(for: paneID) else { return }
        self?.requestClosePane(pane)
      }
    )
  }

  private func updatePaneHeader(for paneID: UUID) {
    guard let pane = pane(for: paneID),
          let header = paneHeaderViews[paneID] else {
      return
    }
    header.rootView = paneHeader(for: pane)
  }

  private func updateAllPaneHeaders() {
    for pane in panes {
      updatePaneHeader(for: pane.id)
    }
  }

  private func splitFromPane(_ paneID: UUID, axis: TerminalWorkspaceSplitAxis) {
    activePaneID = paneID
    openShellPane(axis: axis)
  }

  // MARK: - Workspace Model Helpers

  private var resolvedProjectPath: String {
    configuredProjectPath.isEmpty ? NSHomeDirectory() : configuredProjectPath
  }

  private var activePane: WorkspacePane? {
    pane(for: activePaneID)
  }

  private var activeTab: WorkspaceTab? {
    activePane?.activeTab
  }

  private var protectedAgentTab: WorkspaceTab? {
    guard let protectedAgentPaneID, let protectedAgentTabID else { return nil }
    return pane(for: protectedAgentPaneID)?.tabs.first { $0.id == protectedAgentTabID }
  }

  private var promptTargetTerminal: SafeLocalProcessTerminalView? {
    protectedAgentTab?.terminal ?? activeTab?.terminal
  }

  private func pane(for id: UUID?) -> WorkspacePane? {
    guard let id else { return nil }
    return panes.first { $0.id == id }
  }

  private func allTabs() -> [WorkspaceTab] {
    panes.flatMap(\.tabs)
  }

  private func allTerminalViews() -> [SafeLocalProcessTerminalView] {
    allTabs().map(\.terminal)
  }

  private func tab(for source: TerminalView) -> WorkspaceTab? {
    paneAndTab(for: source)?.tab
  }

  private func paneAndTab(for source: TerminalView) -> (pane: WorkspacePane, tab: WorkspaceTab)? {
    for pane in panes {
      if let tab = pane.tabs.first(where: { $0.terminal === source }) {
        return (pane, tab)
      }
    }
    return nil
  }

  private func paneAndTab(for tabID: UUID) -> (pane: WorkspacePane, tab: WorkspaceTab)? {
    for pane in panes {
      if let tab = pane.tabs.first(where: { $0.id == tabID }) {
        return (pane, tab)
      }
    }
    return nil
  }

  private func prepareShellTabForStartup(_ tab: WorkspaceTab) {
    guard startsTerminalProcesses, tab.role == .shell else { return }
    tab.activity = .starting
    tabActivityTasks[tab.id]?.cancel()

    let tabID = tab.id
    tab.terminal.onProcessReady = { [weak self] in
      self?.finishShellTabStartup(tabID: tabID)
    }
    tabActivityTasks[tab.id] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.shellStartupFallbackDelay)
      guard !Task.isCancelled else { return }
      self?.finishShellTabStartup(tabID: tabID)
    }
  }

  private func finishShellTabStartup(tabID: UUID) {
    tabActivityTasks.removeValue(forKey: tabID)?.cancel()
    guard let (pane, tab) = paneAndTab(for: tabID), tab.activity == .starting else { return }

    tab.activity = nil
    tab.terminal.onProcessReady = nil
    refreshWorkspaceActivityPresentation(
      focusing: pane.id == activePaneID && pane.activeTabID == tab.id
    )
  }

  private func refreshWorkspaceActivityPresentation(focusing shouldFocus: Bool) {
    for pane in panes {
      updatePaneActivityPresentation(for: pane.id)
    }
    if shouldFocus {
      focus()
    }
  }

  private func updatePaneActivityPresentation(for paneID: UUID) {
    guard let pane = pane(for: paneID) else { return }
    updatePaneHeader(for: paneID)
    paneContainerViews[paneID]?.updateActivity(pane.activity ?? pane.activeTab?.activity)
  }

  private func makeShellPane(from snapshot: TerminalWorkspaceTabSnapshot) -> WorkspacePane {
    let tab = makeShellTab(
      name: Self.nonEmpty(snapshot.name) ?? "Shell",
      title: Self.nonEmpty(snapshot.title),
      workingDirectory: resolvedDirectoryForNewShell(snapshot.workingDirectory)
    )
    return WorkspacePane(role: .auxiliary, tabs: [tab])
  }

  private func makeShellTab(
    name: String?,
    title: String?,
    workingDirectory: String
  ) -> WorkspaceTab {
    WorkspaceTab(
      role: .shell,
      name: name,
      title: title,
      workingDirectory: workingDirectory,
      terminal: makeTerminalView(isDark: currentIsDark)
    )
  }

  private func canCloseTab(_ tab: WorkspaceTab, in pane: WorkspacePane) -> Bool {
    if isProtectedAgentTab(tab) {
      return false
    }
    if pane.tabs.count > 1 {
      return true
    }
    return canClosePane(pane)
  }

  private func canClosePane(_ pane: WorkspacePane) -> Bool {
    guard panes.count > 1 else { return false }
    guard !pane.tabs.contains(where: isProtectedAgentTab) else { return false }
    if workspaceMode == .shell {
      return pane.role == .auxiliary
    }
    return true
  }

  private func isProtectedAgentTab(_ tab: WorkspaceTab) -> Bool {
    tab.id == protectedAgentTabID
  }

  private func isProtectedAgentTerminal(_ terminal: SafeLocalProcessTerminalView) -> Bool {
    protectedAgentTab?.terminal === terminal
  }

  private func terminate(_ tab: WorkspaceTab) {
    terminatedWorkspaceTabCount += 1
    tabActivityTasks.removeValue(forKey: tab.id)?.cancel()
    tab.activity = nil
    let key = ObjectIdentifier(tab.terminal)
    if let pid = terminalPidMap.removeValue(forKey: key) {
      TerminalProcessRegistry.shared.unregister(pid: pid)
    }
    tab.terminal.stopReceivingData()
    tab.terminal.terminateProcessTree()
    tab.terminal.removeFromSuperview()
  }

  private func resetWorkspace() {
    cancelAllActivityTasks()
    rootWorkspaceView?.removeFromSuperview()
    rootWorkspaceView = nil
    paneHeaderViews.removeAll()
    paneContainerViews.removeAll()
    paneActiveTabIDs.removeAll()
    panes.removeAll()
    layoutNode = nil
    activePaneID = nil
    protectedAgentPaneID = nil
    protectedAgentTabID = nil
    terminalPidMap.removeAll()
    pendingWorkspaceSnapshot = nil
    lastWorkspaceSnapshot = nil
  }

  private func cancelAllActivityTasks() {
    for task in tabActivityTasks.values {
      task.cancel()
    }
    tabActivityTasks.removeAll()

    for task in paneActivityTasks.values {
      task.cancel()
    }
    paneActivityTasks.removeAll()
  }

  private func resetToPrimaryPaneForRestore() {
    guard let primaryPane = panes.first(where: { $0.role == .primary }) ?? panes.first else { return }
    let keepTab = protectedAgentTab ?? primaryPane.tabs.first

    for pane in panes where pane.id != primaryPane.id {
      for tab in pane.tabs {
        terminate(tab)
      }
    }

    if let keepTab {
      for tab in primaryPane.tabs where tab.id != keepTab.id {
        terminate(tab)
      }
      primaryPane.tabs = [keepTab]
      primaryPane.activeTabID = keepTab.id
    }

    panes = [primaryPane]
    primaryPane.role = .primary
    layoutNode = .pane(primaryPane.id)
    activePaneID = primaryPane.id
  }

  private func restoreTabs(
    from panelSnapshot: TerminalWorkspacePanelSnapshot,
    in pane: WorkspacePane,
    isPrimaryPane: Bool,
    skippingFirstShellTab: Bool = false
  ) {
    var shouldSkipFirstShell = skippingFirstShellTab

    if isPrimaryPane,
       protectedAgentTabID == nil,
       let firstShell = panelSnapshot.tabs.first(where: { $0.role == .shell }),
       let existingTab = pane.tabs.first {
      existingTab.name = Self.nonEmpty(firstShell.name) ?? "Shell"
      existingTab.title = Self.nonEmpty(firstShell.title)
      existingTab.workingDirectory = resolvedDirectoryForNewShell(firstShell.workingDirectory)
      shouldSkipFirstShell = true
    }

    for tabSnapshot in panelSnapshot.tabs where tabSnapshot.role == .shell {
      if shouldSkipFirstShell {
        shouldSkipFirstShell = false
        continue
      }
      openShellTab(in: pane, from: tabSnapshot)
    }
  }

  private func restoreActiveSelection(from snapshot: TerminalWorkspaceSnapshot, paneIDs: [UUID]) {
    guard !paneIDs.isEmpty else { return }
    let paneIndex = min(max(snapshot.activePanelIndex, 0), paneIDs.count - 1)
    let paneID = paneIDs[paneIndex]
    activePaneID = paneID

    guard let pane = pane(for: paneID), !pane.tabs.isEmpty else { return }
    let savedPanel = snapshot.panels.indices.contains(paneIndex) ? snapshot.panels[paneIndex] : nil
    let tabIndex = min(max(savedPanel?.activeTabIndex ?? 0, 0), pane.tabs.count - 1)
    pane.activeTabID = pane.tabs[tabIndex].id
  }

  private func restorePendingWorkspaceSnapshotIfNeeded() {
    guard let snapshot = pendingWorkspaceSnapshot else { return }
    pendingWorkspaceSnapshot = nil
    restoreWorkspaceSnapshot(snapshot)
  }

  private func normalizedPanelSnapshots(_ panels: [TerminalWorkspacePanelSnapshot]) -> [TerminalWorkspacePanelSnapshot] {
    let primary = panels.first { $0.role == .primary } ?? panels.first
    let auxiliaries = panels.filter { $0.role == .auxiliary }
    return ([primary].compactMap { $0 } + auxiliaries).prefix(Self.maxPaneCount).map { $0 }
  }

  private func layout(
    from snapshotNode: TerminalWorkspaceLayoutNode,
    paneIDs: [UUID]
  ) -> WorkspaceLayoutNode? {
    switch snapshotNode {
    case .panel(let index):
      guard paneIDs.indices.contains(index) else { return nil }
      return .pane(paneIDs[index])
    case .split(let axis, let children):
      let restoredChildren = children.compactMap { layout(from: $0, paneIDs: paneIDs) }
      switch restoredChildren.count {
      case 0: return nil
      case 1: return restoredChildren[0]
      default: return .split(axis: axis, children: restoredChildren)
      }
    }
  }

  private func flatLayout(for paneIDs: [UUID], axis: TerminalWorkspaceSplitAxis) -> WorkspaceLayoutNode? {
    guard !paneIDs.isEmpty else { return nil }
    if paneIDs.count == 1 {
      return .pane(paneIDs[0])
    }
    return .split(axis: axis, children: paneIDs.map { .pane($0) })
  }

  private func firstPaneID(in node: WorkspaceLayoutNode?) -> UUID? {
    switch node {
    case .pane(let paneID):
      return paneID
    case .split(_, let children):
      return children.lazy.compactMap { self.firstPaneID(in: $0) }.first
    case nil:
      return nil
    }
  }

  private func resolvedDirectoryForNewShell(_ candidate: String?) -> String {
    guard let candidate = Self.nonEmpty(candidate) else { return resolvedProjectPath }
    let expanded = (candidate as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      return resolvedProjectPath
    }
    return expanded
  }

  private func displayTitle(for tab: WorkspaceTab) -> String {
    if tab.role == .agent {
      return "Agent"
    }
    if let title = Self.nonEmpty(tab.title) {
      return title
    }
    if let name = Self.nonEmpty(tab.name) {
      return name
    }
    return "Shell"
  }

  private func resolvedFont() -> NSFont {
    let resolvedSize = max(currentFontSize, 8)
    return NSFont(name: currentFontFamily, size: resolvedSize)
      ?? NSFont(name: "SF Mono", size: resolvedSize)
      ?? NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
  }

  private func applyColors(to terminal: TerminalView, isDark: Bool, theme: TerminalAppearanceTheme?) {
    if isDark, let bg = theme?.terminalBackground {
      terminal.nativeBackgroundColor = bg
    } else if isDark {
      terminal.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
    } else {
      terminal.nativeBackgroundColor = NSColor(red: 250/255, green: 249/255, blue: 245/255, alpha: 1.0)
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
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  // MARK: - Interaction Helpers

  private func focusedTerminal(in window: NSWindow) -> SafeLocalProcessTerminalView? {
    guard let responder = window.firstResponder else { return nil }
    for terminal in visibleTerminalViews() {
      if responder === terminal { return terminal }
      if let responderView = responder as? NSView, responderView.isDescendant(of: terminal) {
        return terminal
      }
    }
    return nil
  }

  private func terminal(containingMouseEvent event: NSEvent) -> SafeLocalProcessTerminalView? {
    visibleTerminalViews().first { terminal in
      guard event.window === terminal.window else { return false }
      let location = terminal.convert(event.locationInWindow, from: nil)
      return terminal.bounds.contains(location)
    }
  }

  private func visibleTerminalViews() -> [SafeLocalProcessTerminalView] {
    panes.compactMap { $0.activeTab?.terminal }
  }

  private func syncActiveSelection(to terminal: SafeLocalProcessTerminalView) {
    for pane in panes {
      guard let tab = pane.tabs.first(where: { $0.terminal === terminal }) else { continue }
      let changed = pane.activeTabID != tab.id || activePaneID != pane.id
      pane.activeTabID = tab.id
      activePaneID = pane.id
      if changed {
        updateAllPaneHeaders()
        notifyWorkspaceChanged()
      }
      return
    }
  }

  private func notifyWorkspaceChanged() {
    guard !isRestoringWorkspace else { return }
    guard let snapshot = captureWorkspaceSnapshot() else { return }
    guard snapshot != lastWorkspaceSnapshot else { return }
    lastWorkspaceSnapshot = snapshot
    onWorkspaceChanged?(snapshot)
  }

  // MARK: - Test Hooks

  func _testingDisableProcessLaunch() {
    startsTerminalProcesses = false
  }

  var _testingPaneCount: Int {
    panes.count
  }

  var _testingTabCounts: [Int] {
    panes.map(\.tabs.count)
  }

  var _testingTerminatedTabCount: Int {
    terminatedWorkspaceTabCount
  }

  var _testingActiveTabRole: TerminalWorkspaceTabRole? {
    activeTab?.role
  }

  var _testingPromptTargetRole: TerminalWorkspaceTabRole? {
    protectedAgentTab?.role ?? activeTab?.role
  }

  func _testingOpenShellTab() {
    openShellTab()
  }

  func _testingOpenVerticalSplit() {
    openShellPane(axis: .vertical)
  }

  func _testingOpenHorizontalSplit() {
    openShellPane(axis: .horizontal)
  }

  func _testingSelectTab(panelIndex: Int, tabIndex: Int) {
    guard panes.indices.contains(panelIndex) else { return }
    let pane = panes[panelIndex]
    guard pane.tabs.indices.contains(tabIndex) else { return }
    selectTab(pane.tabs[tabIndex].id, in: pane.id)
  }

  func _testingCloseTab(panelIndex: Int, tabIndex: Int) {
    guard panes.indices.contains(panelIndex) else { return }
    let pane = panes[panelIndex]
    guard pane.tabs.indices.contains(tabIndex) else { return }
    closeTab(pane.tabs[tabIndex].id, in: pane.id)
  }

  func _testingCanClosePane(panelIndex: Int) -> Bool {
    guard panes.indices.contains(panelIndex) else { return false }
    return canClosePane(panes[panelIndex])
  }

  func _testingClosePane(panelIndex: Int) {
    guard panes.indices.contains(panelIndex) else { return }
    closePane(panes[panelIndex])
  }
}

private extension TerminalContainerView.WorkspaceLayoutNode {
  func replacingPane(
    _ targetPaneID: UUID,
    withSplitAxis axis: TerminalWorkspaceSplitAxis,
    newPaneID: UUID
  ) -> TerminalContainerView.WorkspaceLayoutNode {
    switch self {
    case .pane(let paneID) where paneID == targetPaneID:
      return .split(axis: axis, children: [.pane(paneID), .pane(newPaneID)])
    case .pane:
      return self
    case .split(let existingAxis, let children):
      return .split(
        axis: existingAxis,
        children: children.map {
          $0.replacingPane(targetPaneID, withSplitAxis: axis, newPaneID: newPaneID)
        }
      )
    }
  }

  func removingPane(_ targetPaneID: UUID) -> TerminalContainerView.WorkspaceLayoutNode? {
    switch self {
    case .pane(let paneID):
      return paneID == targetPaneID ? nil : self
    case .split(let axis, let children):
      let remaining = children.compactMap { $0.removingPane(targetPaneID) }
      switch remaining.count {
      case 0:
        return nil
      case 1:
        return remaining[0]
      default:
        return .split(axis: axis, children: remaining)
      }
    }
  }

  func snapshot(indexByPaneID: [UUID: Int]) -> TerminalWorkspaceLayoutNode? {
    switch self {
    case .pane(let paneID):
      guard let index = indexByPaneID[paneID] else { return nil }
      return .panel(index: index)
    case .split(let axis, let children):
      let snapshotChildren = children.compactMap { $0.snapshot(indexByPaneID: indexByPaneID) }
      guard !snapshotChildren.isEmpty else { return nil }
      return .split(axis: axis, children: snapshotChildren)
    }
  }
}
