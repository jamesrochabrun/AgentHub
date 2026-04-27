//
//  AgentHubGhosttyTerminalSurface.swift
//  AgentHub
//

import AppKit
import GhosttySwift
import SwiftUI

@MainActor
final class AgentHubGhosttyTerminalSurface: NSView, EmbeddedTerminalSurface {
  private var terminalSession: TerminalSession?
  private var hostingView: NSHostingView<TerminalSurfaceView>?
  private var protectedAgentPanelID: TerminalPanelID?
  private var protectedAgentTabID: TerminalTabID?
  private var isConfigured = false
  private var hasDeliveredInitialPrompt = false
  private var hasPrefilledInitialInputText = false
  private var registeredPIDs: [ObjectIdentifier: pid_t] = [:]
  private var pidRegistrationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var localEventMonitor: Any?
  private var projectPath: String = ""

  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  private var terminalSessionKey: String?
  private weak var sessionViewModel: CLISessionsViewModel?
  var terminateProcessCallCount = 0

  var view: NSView { self }

  var currentProcessPID: Int32? {
    protectedAgentController?.foregroundProcessID ?? activeController?.foregroundProcessID
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleKeyDown(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  deinit {
    if let localEventMonitor {
      NSEvent.removeMonitor(localEventMonitor)
    }
    MainActor.assumeIsolated {
      terminalSession?.requestCloseAll()
      cancelPIDRegistrationTasks()
      unregisterAllPIDs()
    }
  }

  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {
    self.terminalSessionKey = terminalSessionKey
    self.sessionViewModel = sessionViewModel
  }

  func configure(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?,
    initialInputText: String?,
    isDark: Bool,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool,
    worktreeName: String?,
    metadataStore: SessionMetadataStore?
  ) {
    guard !isConfigured else { return }
    isConfigured = true
    self.projectPath = projectPath

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

    switch launch {
    case .success(let launch):
      mountGhosttySession(
        primaryConfiguration: makeGhosttyConfiguration(
          command: launch.ghosttyCommand,
          environment: launch.environment,
          initialInput: initialInputText,
          workingDirectory: resolvedProjectPath
        ),
        protectsPrimaryTab: true
      )
    case .failure(let error):
      mountError(error.localizedDescription)
    }
  }

  func configureShell(projectPath: String, isDark: Bool, shellPath: String?) {
    guard !isConfigured else { return }
    isConfigured = true
    self.projectPath = projectPath

    let launch = EmbeddedTerminalLaunchBuilder.shellLaunch(
      projectPath: projectPath,
      shellPath: shellPath
    )
    mountGhosttySession(
      primaryConfiguration: makeGhosttyConfiguration(
        command: launch.ghosttyCommand,
        environment: launch.environment,
        initialInput: nil,
        workingDirectory: resolvedProjectPath
      ),
      protectsPrimaryTab: false
    )
  }

  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {
    terminateProcess()
    removeMountedContent()
    terminalSession = nil
    protectedAgentPanelID = nil
    protectedAgentTabID = nil
    isConfigured = false
    hasDeliveredInitialPrompt = false
    hasPrefilledInitialInputText = false
    configure(
      sessionId: sessionId,
      projectPath: projectPath,
      cliConfiguration: cliConfiguration,
      initialPrompt: nil,
      initialInputText: nil,
      isDark: true,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil
    )
  }

  func terminateProcess() {
    terminateProcessCallCount += 1
    terminalSession?.requestCloseAll()
    cancelPIDRegistrationTasks()
    unregisterAllPIDs()
  }

  func resetPromptDeliveryFlag() {
    hasDeliveredInitialPrompt = false
  }

  func sendPromptIfNeeded(_ prompt: String) {
    guard !hasDeliveredInitialPrompt else { return }
    hasDeliveredInitialPrompt = true
    focusProtectedAgentTab()

    let planFeedbackPrefix = "\u{1B}[B\u{1B}[B\u{1B}[B\r"
    if prompt.hasPrefix(planFeedbackPrefix) {
      let feedback = String(prompt.dropFirst(planFeedbackPrefix.count))
      Task { @MainActor [weak self] in
        self?.protectedAgentController?.sendArrowDownKey()
        try? await Task.sleep(for: .milliseconds(80))
        self?.protectedAgentController?.sendArrowDownKey()
        try? await Task.sleep(for: .milliseconds(80))
        self?.protectedAgentController?.sendArrowDownKey()
        try? await Task.sleep(for: .milliseconds(80))
        self?.protectedAgentController?.sendReturnKey()
        try? await Task.sleep(for: .milliseconds(150))
        if !feedback.isEmpty {
          self?.protectedAgentController?.sendText(feedback)
          try? await Task.sleep(for: .milliseconds(100))
        }
        self?.protectedAgentController?.sendReturnKey()
      }
      return
    }

    protectedAgentController?.sendText(prompt)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      self?.protectedAgentController?.sendReturnKey()
    }
  }

  func submitPromptImmediately(_ prompt: String) -> Bool {
    guard protectedAgentController != nil else { return false }
    focusProtectedAgentTab()
    protectedAgentController?.sendText(prompt)
    let delay = Self.submitDelay(forByteCount: prompt.utf8.count)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      self?.protectedAgentController?.sendReturnKey()
    }
    return true
  }

  func typeText(_ text: String) {
    activeController?.sendText(text)
  }

  func typeInitialTextIfNeeded(_ text: String) {
    guard !text.isEmpty else { return }
    guard !hasPrefilledInitialInputText else { return }
    hasPrefilledInitialInputText = true
    focusProtectedAgentTab()
    protectedAgentController?.sendText(text)
  }

  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {
    // Ghostty owns live appearance through its config. Font size is applied at surface creation.
  }

  func focus() {
    activeController?.focusTerminal()
  }

  private var resolvedProjectPath: String {
    projectPath.isEmpty ? NSHomeDirectory() : projectPath
  }

  private var activeController: GhosttyTerminalController? {
    terminalSession?.activeTab?.controller
  }

  private var protectedAgentController: GhosttyTerminalController? {
    guard
      let terminalSession,
      let protectedAgentPanelID,
      let protectedAgentTabID
    else {
      return nil
    }
    return terminalSession.controller(for: protectedAgentTabID, in: protectedAgentPanelID)
  }

  private func mountGhosttySession(
    primaryConfiguration: GhosttySurfaceConfiguration,
    protectsPrimaryTab: Bool
  ) {
    do {
      let session = try TerminalSession(
        primaryConfiguration: primaryConfiguration,
        primaryName: protectsPrimaryTab ? "Agent" : "Shell"
      )
      if protectsPrimaryTab, let primaryTab = session.primaryPanel.activeTab {
        protectedAgentPanelID = session.primaryPanelID
        protectedAgentTabID = primaryTab.id
      }
      configureControllerHooks(for: session.primaryPanel.activeTab?.controller)
      mount(session)
      terminalSession = session
      installInteractionMonitorIfNeeded()
    } catch {
      mountError(error.localizedDescription)
    }
  }

  private func mount(_ session: TerminalSession) {
    let host = NSHostingView(
      rootView: TerminalSurfaceView(
        session: session,
        showsPaneLabels: false,
        showsTabBar: true,
        allowsClosingPanels: true,
        allowsClosingTabs: true,
        panelClosePolicy: { [weak self] panel in
          self?.canCloseGhosttyPanel(panel) ?? false
        },
        tabClosePolicy: { [weak self] panel, tab in
          self?.canCloseGhosttyTab(tab, in: panel) ?? false
        },
        onClosePanel: { [weak self] panel in
          self?.closeGhosttyPanel(panel)
        },
        onCloseTab: { [weak self] panel, tab in
          self?.closeGhosttyTab(tab, in: panel)
        }
      )
    )
    mount(host)
    hostingView = host
  }

  private func mount(_ child: NSView) {
    child.translatesAutoresizingMaskIntoConstraints = false
    addSubview(child)
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: leadingAnchor),
      child.trailingAnchor.constraint(equalTo: trailingAnchor),
      child.topAnchor.constraint(equalTo: topAnchor),
      child.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  private func removeMountedContent() {
    hostingView?.removeFromSuperview()
    hostingView = nil
    for subview in subviews {
      subview.removeFromSuperview()
    }
  }

  private func mountError(_ message: String) {
    removeMountedContent()
    let label = NSTextField(wrappingLabelWithString: "\nError: \(message)\nPlease ensure the CLI is installed.")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.alignment = .center
    label.textColor = .secondaryLabelColor
    addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      trailingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 24)
    ])
  }

  private func makeGhosttyConfiguration(
    command: String,
    environment: [String: String],
    initialInput: String?,
    workingDirectory: String
  ) -> GhosttySurfaceConfiguration {
    GhosttySurfaceConfiguration(
      workingDirectory: workingDirectory,
      command: command,
      environment: environment,
      initialInput: initialInput,
      fontSize: resolvedFontSize()
    )
  }

  private func shellConfigurationForNewTerminal() -> GhosttySurfaceConfiguration {
    let workingDirectory = activeController?.workingDirectory
      ?? activeController?.configuration.workingDirectory
      ?? resolvedProjectPath
    let launch = EmbeddedTerminalLaunchBuilder.shellLaunch(projectPath: workingDirectory)
    return makeGhosttyConfiguration(
      command: launch.ghosttyCommand,
      environment: launch.environment,
      initialInput: nil,
      workingDirectory: workingDirectory
    )
  }

  private func resolvedFontSize() -> Float {
    let fontSize = Float(UserDefaults.standard.double(forKey: AgentHubDefaults.terminalFontSize))
    return fontSize > 0 ? fontSize : 12
  }

  private static func submitDelay(forByteCount count: Int) -> Duration {
    switch count {
    case ..<500:   return .milliseconds(100)
    case ..<2000:  return .milliseconds(250)
    default:       return .milliseconds(500)
    }
  }

  private func installInteractionMonitorIfNeeded() {
    guard localEventMonitor == nil else { return }
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
      guard let self else { return event }

      switch event.type {
      case .keyDown:
        return handleKeyDown(event) ? nil : event
      case .leftMouseUp:
        handleMouseUp(event)
      default:
        break
      }

      return event
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    guard let window = event.window ?? self.window, window === self.window else { return false }
    guard let focusedTab = focusedTab(in: window) else { return false }
    syncSessionSelection(to: focusedTab)

    if let shortcut = AgentHubGhosttyTerminalShortcut.action(for: event) {
      handleShortcut(shortcut)
      onUserInteraction?()
      return true
    }

    let flags = normalizedModifierFlags(event.modifierFlags)
    if flags == .control,
       event.keyCode == 50,
       onRequestShowEditor != nil {
      onRequestShowEditor?()
      onUserInteraction?()
      return true
    }

    guard isProtectedAgentTab(focusedTab) else {
      onUserInteraction?()
      return false
    }

    let shortcut = NewlineShortcut(
      rawValue: UserDefaults.standard.integer(forKey: AgentHubDefaults.terminalNewlineShortcut)
    ) ?? .system
    let action = TerminalSubmitInterception.keyAction(
      shortcut: shortcut,
      isReturn: event.keyCode == 36,
      flags: flags
    )
    let queuedContextPrompt: String?
    switch action {
    case .submit, .systemSubmit:
      queuedContextPrompt = consumeQueuedWebPreviewContextOnSubmit?()
    case .passthrough, .newline:
      queuedContextPrompt = nil
    }

    switch TerminalSubmitInterception.dispatch(for: action, queuedContextPrompt: queuedContextPrompt) {
    case .passthrough:
      onUserInteraction?()
      return false
    case .newline:
      protectedAgentController?.sendText("\n")
      onUserInteraction?()
      return true
    case .submit:
      protectedAgentController?.sendReturnKey()
      onUserInteraction?()
      return true
    case .appendContextAndSubmit(let queuedContextPrompt):
      let fullText = "\n\n\(queuedContextPrompt)"
      protectedAgentController?.sendText(fullText)
      let delay = Self.submitDelay(forByteCount: fullText.utf8.count)
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: delay)
        self?.protectedAgentController?.sendReturnKey()
      }
      onUserInteraction?()
      return true
    }
  }

  private func handleMouseUp(_ event: NSEvent) {
    guard let window = event.window, window === self.window else { return }
    guard let tab = tab(containingMouseEvent: event) else { return }
    syncSessionSelection(to: tab)
    DispatchQueue.main.async { [weak self] in
      self?.onUserInteraction?()
    }
  }

  private func handleShortcut(_ shortcut: AgentHubGhosttyTerminalShortcut) {
    switch shortcut {
    case .startSearch:
      _ = activeController?.startSearch()
    case .searchNext:
      _ = activeController?.navigateSearchNext()
    case .searchPrevious:
      _ = activeController?.navigateSearchPrevious()
    case .openTab:
      openShellTab()
    case .openPane:
      openShellPane()
    case .closePanel:
      closeActiveOrLastAuxiliaryPanel()
    case .focusPanel(let direction):
      _ = terminalSession?.focusPanel(direction: direction)
    case .selectTab(let direction):
      _ = terminalSession?.selectTab(direction: direction)
    }
  }

  private func openShellTab() {
    guard let terminalSession else { return }
    do {
      let tab = try terminalSession.openTab(
        named: "Shell",
        configuration: shellConfigurationForNewTerminal()
      )
      configureControllerHooks(for: tab.controller)
    } catch {
      AppLogger.session.error("Failed to open Ghostty shell tab: \(error.localizedDescription)")
    }
  }

  private func openShellPane() {
    guard let terminalSession, terminalSession.canOpenPanel else { return }
    do {
      let panel = try terminalSession.openPanel(
        named: "Shell",
        configuration: shellConfigurationForNewTerminal()
      )
      configureControllerHooks(for: panel.activeTab?.controller)
    } catch {
      AppLogger.session.error("Failed to open Ghostty shell pane: \(error.localizedDescription)")
    }
  }

  private func closeActiveOrLastAuxiliaryPanel() {
    guard let terminalSession else { return }
    let targetPanel = terminalSession.activePanelID == terminalSession.primaryPanelID
      ? terminalSession.visiblePanels.reversed().first { $0.id != terminalSession.primaryPanelID }
      : terminalSession.panel(for: terminalSession.activePanelID)

    guard let targetPanel, targetPanel.id != terminalSession.primaryPanelID else { return }
    closeGhosttyPanel(targetPanel)
  }

  private func canCloseGhosttyPanel(_ panel: TerminalPanel) -> Bool {
    guard let terminalSession else { return false }
    return panel.id != terminalSession.primaryPanelID
  }

  private func canCloseGhosttyTab(_ tab: TerminalTab, in panel: TerminalPanel) -> Bool {
    !isProtectedAgentTab(tab, in: panel.id)
  }

  private func closeGhosttyPanel(_ panel: TerminalPanel) {
    guard let terminalSession, canCloseGhosttyPanel(panel) else { return }
    requestClose(panel)
    _ = terminalSession.closePanel(panel.id)
  }

  private func closeGhosttyTab(_ tab: TerminalTab, in panel: TerminalPanel) {
    guard let terminalSession, canCloseGhosttyTab(tab, in: panel) else { return }
    requestClose(tab)
    _ = terminalSession.closeTab(tab.id, in: panel.id)
  }

  private func requestClose(_ panel: TerminalPanel) {
    for tab in panel.tabs {
      requestClose(tab)
    }
  }

  private func requestClose(_ tab: TerminalTab) {
    tab.controller.requestClose()
    unregisterPID(for: tab.controller)
  }

  private func focusProtectedAgentTab() {
    guard
      let terminalSession,
      let protectedAgentPanelID,
      let protectedAgentTabID
    else {
      return
    }
    _ = terminalSession.selectTab(protectedAgentTabID, in: protectedAgentPanelID)
  }

  private func configureControllerHooks(for controller: GhosttyTerminalController?) {
    guard let controller else { return }
    controller.closesHostWindowOnClose = false
    controller.onClose = { [weak self, weak controller] _ in
      guard let self, let controller else { return }
      self.unregisterPID(for: controller)
    }
    controller.onCloseWindow = { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.closeControllerIfAllowed(controller)
    }
    controller.onOpenURL = { [weak self] url in
      self?.handleOpenURL(url) ?? false
    }
    registerPIDWhenAvailable(for: controller)
  }

  private func closeControllerIfAllowed(_ controller: GhosttyTerminalController) {
    guard
      let terminalSession,
      let located = locateController(controller)
    else {
      return
    }
    guard !isProtectedAgentTab(located.tab, in: located.panel.id) else { return }
    requestClose(located.tab)
    _ = terminalSession.closeTab(located.tab.id, in: located.panel.id)
  }

  private func focusedTab(in window: NSWindow) -> TerminalTab? {
    guard let responder = window.firstResponder else { return nil }
    if let focusedTab = allTabs().first(where: { tab in
      guard let responderView = responder as? NSView else {
        return responder === tab.containerView.surfaceView
      }

      return responderView === tab.containerView
        || responderView === tab.containerView.surfaceView
        || responderView.isDescendant(of: tab.containerView)
    }) {
      return focusedTab
    }

    guard let responderView = responder as? NSView else { return nil }
    if responderView === self || responderView.isDescendant(of: self) {
      return terminalSession?.activeTab
    }

    return nil
  }

  private func tab(containingMouseEvent event: NSEvent) -> TerminalTab? {
    allTabs().first { tab in
      guard event.window === tab.containerView.window else { return false }
      let location = tab.containerView.convert(event.locationInWindow, from: nil)
      return tab.containerView.bounds.contains(location)
    }
  }

  private func syncSessionSelection(to tab: TerminalTab) {
    guard let terminalSession, let located = locateTab(tab) else { return }
    if terminalSession.activePanelID != located.panel.id || located.panel.activeTabID != tab.id {
      _ = terminalSession.selectTab(tab.id, in: located.panel.id)
    }
  }

  private func isProtectedAgentTab(_ tab: TerminalTab) -> Bool {
    guard let located = locateTab(tab) else { return false }
    return isProtectedAgentTab(tab, in: located.panel.id)
  }

  private func isProtectedAgentTab(_ tab: TerminalTab, in panelID: TerminalPanelID) -> Bool {
    panelID == protectedAgentPanelID && tab.id == protectedAgentTabID
  }

  private func locateTab(_ tab: TerminalTab) -> (panel: TerminalPanel, tab: TerminalTab)? {
    for panel in terminalSession?.panels ?? [] {
      if let matchedTab = panel.tabs.first(where: { $0.id == tab.id }) {
        return (panel, matchedTab)
      }
    }
    return nil
  }

  private func locateController(
    _ controller: GhosttyTerminalController
  ) -> (panel: TerminalPanel, tab: TerminalTab)? {
    for panel in terminalSession?.panels ?? [] {
      if let tab = panel.tabs.first(where: { $0.controller === controller }) {
        return (panel, tab)
      }
    }
    return nil
  }

  private func allTabs() -> [TerminalTab] {
    terminalSession?.panels.flatMap(\.tabs) ?? []
  }

  private func normalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.numericPad, .function, .capsLock])
  }

  private func registerPIDWhenAvailable(for controller: GhosttyTerminalController) {
    let id = ObjectIdentifier(controller)
    pidRegistrationTasks[id]?.cancel()
    pidRegistrationTasks[id] = Task { @MainActor [weak self, weak controller] in
      for _ in 0..<10 {
        guard let self, let controller else { return }
        guard self.locateController(controller) != nil else { return }
        if let pid = controller.foregroundProcessID, pid > 0 {
          self.registeredPIDs[id] = pid
          TerminalProcessRegistry.shared.register(pid: pid)
          self.pidRegistrationTasks[id] = nil
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      self?.pidRegistrationTasks[id] = nil
    }
  }

  private func unregisterPID(for controller: GhosttyTerminalController) {
    let id = ObjectIdentifier(controller)
    pidRegistrationTasks[id]?.cancel()
    pidRegistrationTasks[id] = nil
    if let registeredPID = registeredPIDs.removeValue(forKey: id) {
      TerminalProcessRegistry.shared.unregister(pid: registeredPID)
    }
  }

  private func cancelPIDRegistrationTasks() {
    for task in pidRegistrationTasks.values {
      task.cancel()
    }
    pidRegistrationTasks.removeAll()
  }

  private func unregisterAllPIDs() {
    for pid in registeredPIDs.values {
      TerminalProcessRegistry.shared.unregister(pid: pid)
    }
    registeredPIDs.removeAll()
  }

  private func handleOpenURL(_ value: String) -> Bool {
    if let fileLink = filePathFromImplicitLink(value) {
      requestOpenFile(path: fileLink.path, lineNumber: fileLink.lineNumber)
      return true
    }

    guard let url = URL(string: value), url.scheme != nil else {
      return false
    }
    NSWorkspace.shared.open(url)
    return true
  }

  private func requestOpenFile(path: String, lineNumber: Int?) {
    let resolvedPath: String
    if path.hasPrefix("/") || path.hasPrefix("~") {
      resolvedPath = (path as NSString).expandingTildeInPath
    } else if !projectPath.isEmpty {
      resolvedPath = (projectPath as NSString).appendingPathComponent(path)
    } else {
      resolvedPath = (NSHomeDirectory() as NSString).appendingPathComponent(path)
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
      return
    }

    let editor = FileOpenEditor(
      rawValue: UserDefaults.standard.integer(forKey: AgentHubDefaults.terminalFileOpenEditor)
    ) ?? .agentHub
    switch editor {
    case .agentHub:
      if let vm = sessionViewModel, let key = terminalSessionKey {
        vm.pendingFileOpen = (sessionId: key, filePath: resolvedPath, lineNumber: lineNumber)
      }
    case .vscode:
      openInVSCode(path: resolvedPath, line: lineNumber)
    case .xcode:
      openInXcode(path: resolvedPath, line: lineNumber)
    }
  }

  private func openInVSCode(path: String, line: Int?) {
    let codePaths = [
      "/usr/local/bin/code",
      "/opt/homebrew/bin/code",
      "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    ]
    guard let codePath = codePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      NSWorkspace.shared.open(URL(fileURLWithPath: path))
      return
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: codePath)
    task.arguments = ["--goto", line != nil ? "\(path):\(line!)" : path]
    try? task.run()
  }

  private func openInXcode(path: String, line: Int?) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
    task.arguments = line != nil ? ["--line", "\(line!)", path] : [path]
    try? task.run()
  }

  private func filePathFromImplicitLink(_ link: String) -> (path: String, lineNumber: Int?)? {
    let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed), url.isFileURL {
      return (url.path, nil)
    }

    guard !trimmed.contains("://"),
          URLComponents(string: trimmed)?.scheme == nil,
          trimmed.contains("/")
            || trimmed.hasPrefix("~")
            || trimmed.hasPrefix(".")
            || trimmed.hasPrefix("/")
    else {
      return nil
    }

    var path = trimmed
    var lineNumber: Int?
    if let suffixRange = path.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
      let suffix = String(path[suffixRange])
      let parts = suffix.dropFirst().split(separator: ":")
      lineNumber = parts.first.flatMap { Int($0) }
      path = String(path[..<suffixRange.lowerBound])
    }

    return path.isEmpty ? nil : (path, lineNumber)
  }
}
