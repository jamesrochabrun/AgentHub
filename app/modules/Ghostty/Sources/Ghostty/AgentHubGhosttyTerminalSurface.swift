//
//  AgentHubGhosttyTerminalSurface.swift
//  AgentHub
//

import AgentHubCore
import AppKit
import GhosttySwift
import SwiftUI

@MainActor
public final class AgentHubGhosttyTerminalSurface: NSView, EmbeddedTerminalSurface {
  private struct PendingMount {
    let command: String
    let environment: [String: String]
    let initialInput: String?
    let workingDirectory: String
    let protectsPrimaryTab: Bool
  }

  private var terminalSession: TerminalSession?
  private var hostingView: NSHostingView<TerminalSurfaceView>?
  private var protectedAgentPanelID: TerminalPanelID?
  private var protectedAgentTabID: TerminalTabID?
  private var pendingMount: PendingMount?
  private var pendingWorkspaceSnapshot: TerminalWorkspaceSnapshot?
  private var isConfigured = false
  private var hasDeliveredInitialPrompt = false
  private var hasPrefilledInitialInputText = false
  private var registeredPIDs: [ObjectIdentifier: pid_t] = [:]
  private var pidRegistrationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var localEventMonitor: Any?
  private var projectPath: String = ""
  private var isRestoringWorkspace = false
  private var lastWorkspaceSnapshot: TerminalWorkspaceSnapshot?
  private static let terminalPaneDividerSize: CGFloat = 1
  private static let terminalTabStripHeight: CGFloat = 24

  public var onUserInteraction: (() -> Void)?
  public var onRequestShowEditor: (() -> Void)?
  public var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  public var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)?
  private var terminalSessionKey: String?
  private weak var sessionViewModel: CLISessionsViewModel?
  var terminateProcessCallCount = 0

  public var view: NSView { self }

  public var currentProcessPID: Int32? {
    protectedAgentController?.foregroundProcessID ?? activeController?.foregroundProcessID
  }

  public override var isOpaque: Bool { false }

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    makeViewTransparent(self)
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    makeViewTransparent(self)
  }

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleKeyDown(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    mountPendingGhosttySessionIfReady()
  }

  public override func layout() {
    super.layout()
    mountPendingGhosttySessionIfReady()
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

  public func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {
    self.terminalSessionKey = terminalSessionKey
    self.sessionViewModel = sessionViewModel
  }

  public func configure(
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
      queueOrMountGhosttySession(
        PendingMount(
          command: launch.ghosttyCommand,
          environment: launch.environment,
          initialInput: initialInputText,
          workingDirectory: resolvedProjectPath,
          protectsPrimaryTab: true
        )
      )
    case .failure(let error):
      mountError(error.localizedDescription)
    }
  }

  public func configureShell(projectPath: String, isDark: Bool, shellPath: String?) {
    guard !isConfigured else { return }
    isConfigured = true
    self.projectPath = projectPath

    let launch = EmbeddedTerminalLaunchBuilder.shellLaunch(
      projectPath: projectPath,
      shellPath: shellPath
    )
    queueOrMountGhosttySession(
      PendingMount(
        command: launch.ghosttyCommand,
        environment: launch.environment,
        initialInput: nil,
        workingDirectory: resolvedProjectPath,
        protectsPrimaryTab: false
      )
    )
  }

  public func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {
    terminateProcess()
    removeMountedContent()
    terminalSession = nil
    pendingMount = nil
    pendingWorkspaceSnapshot = nil
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

  public func terminateProcess() {
    terminateProcessCallCount += 1
    terminalSession?.requestCloseAll()
    cancelPIDRegistrationTasks()
    unregisterAllPIDs()
  }

  public func resetPromptDeliveryFlag() {
    hasDeliveredInitialPrompt = false
  }

  public func sendPromptIfNeeded(_ prompt: String) {
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

    sendBracketedPasteText(prompt, to: protectedAgentController)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      self?.protectedAgentController?.sendReturnKey()
    }
  }

  public func submitPromptImmediately(_ prompt: String) -> Bool {
    guard protectedAgentController != nil else { return false }
    focusProtectedAgentTab()
    sendBracketedPasteText(prompt, to: protectedAgentController)
    let delay = Self.submitDelay(forByteCount: prompt.utf8.count)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      self?.protectedAgentController?.sendReturnKey()
    }
    return true
  }

  public func typeText(_ text: String) {
    activeController?.sendText(text)
  }

  public func typeInitialTextIfNeeded(_ text: String) {
    guard !text.isEmpty else { return }
    guard !hasPrefilledInitialInputText else { return }
    hasPrefilledInitialInputText = true
    focusProtectedAgentTab()
    protectedAgentController?.sendText(text)
  }

  public func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {
    // Ghostty owns live appearance through its config. Font size is applied at surface creation.
  }

  public func focus() {
    activeController?.focusTerminal()
  }

  public func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? {
    guard let terminalSession else { return nil }

    let panels = terminalSession.panels.map { panel in
      let tabs = panel.tabs.map { tab in
        TerminalWorkspaceTabSnapshot(
          role: isProtectedAgentTab(tab, in: panel.id) ? .agent : .shell,
          name: Self.nonEmpty(tab.name),
          title: Self.nonEmpty(tab.title),
          workingDirectory: Self.nonEmpty(
            tab.controller.workingDirectory
              ?? tab.controller.configuration.workingDirectory
              ?? resolvedProjectPath
          )
        )
      }
      let activeTabIndex = panel.tabs.firstIndex { $0.id == panel.activeTabID } ?? 0
      return TerminalWorkspacePanelSnapshot(
        role: panel.id == terminalSession.primaryPanelID ? .primary : .auxiliary,
        tabs: tabs,
        activeTabIndex: activeTabIndex
      )
    }

    return TerminalWorkspaceSnapshot(
      panels: panels,
      activePanelIndex: terminalSession.panels.firstIndex { $0.id == terminalSession.activePanelID } ?? 0
    )
  }

  public func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) {
    guard let terminalSession else {
      pendingWorkspaceSnapshot = snapshot
      return
    }
    guard !snapshot.panels.isEmpty else { return }

    isRestoringWorkspace = true
    defer {
      isRestoringWorkspace = false
      lastWorkspaceSnapshot = captureWorkspaceSnapshot()
    }

    resetToPrimaryAgentTab(in: terminalSession)

    let panelSnapshots = normalizedPanelSnapshots(snapshot.panels)
    var restoredPanelIDs: [TerminalPanelID] = [terminalSession.primaryPanelID]
    var restoredTabIDs: [[TerminalTabID]] = [[protectedAgentTabID ?? terminalSession.primaryPanel.activeTabID]]

    if let primarySnapshot = panelSnapshots.first {
      restoredTabIDs[0] = restoreShellTabs(
        from: primarySnapshot,
        in: terminalSession.primaryPanelID,
        existingTabIDs: restoredTabIDs[0]
      )
    }

    for panelSnapshot in panelSnapshots.dropFirst() {
      guard terminalSession.canOpenPanel else { break }
      guard let firstShellTab = panelSnapshot.tabs.first(where: { $0.role == .shell }) else { continue }

      do {
        let panel = try terminalSession.openPanel(
          named: restoredTabName(for: firstShellTab),
          configuration: shellConfiguration(forRestoredWorkingDirectory: firstShellTab.workingDirectory)
        )
        configureControllerHooks(for: panel.activeTab?.controller)
        restoredPanelIDs.append(panel.id)

        var tabIDs = panel.activeTab.map { [$0.id] } ?? []
        tabIDs = restoreShellTabs(
          from: panelSnapshot,
          in: panel.id,
          existingTabIDs: tabIDs,
          skippingFirstShellTab: true
        )
        restoredTabIDs.append(tabIDs)
      } catch {
        AppLogger.session.error("Failed to restore Ghostty shell pane: \(error.localizedDescription)")
      }
    }

    terminalSession.showPrimaryAndAuxiliaries()
    restoreActiveSelection(
      from: snapshot,
      panelIDs: restoredPanelIDs,
      tabIDs: restoredTabIDs
    )
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
      AgentHubGhosttyRuntimeLogging.applyQuietDefault()
      let session = try TerminalSession(
        configPath: GhosttyConfigPathResolver.configuredPath(),
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
      restorePendingWorkspaceSnapshotIfNeeded()
      installInteractionMonitorIfNeeded()
    } catch {
      mountError(error.localizedDescription)
    }
  }

  private func queueOrMountGhosttySession(_ pendingMount: PendingMount) {
    guard canMountGhosttySession else {
      self.pendingMount = pendingMount
      needsLayout = true
      return
    }

    mountGhosttySession(pendingMount)
  }

  private func mountPendingGhosttySessionIfReady() {
    guard let pendingMount, canMountGhosttySession else { return }
    self.pendingMount = nil
    mountGhosttySession(pendingMount)
  }

  private var canMountGhosttySession: Bool {
    window != nil && bounds.width > 0 && bounds.height > 0
  }

  private func mountGhosttySession(_ pendingMount: PendingMount) {
    mountGhosttySession(
      primaryConfiguration: makeGhosttyConfiguration(
        command: pendingMount.command,
        environment: pendingMount.environment,
        initialInput: pendingMount.initialInput,
        workingDirectory: pendingMount.workingDirectory,
        initialSize: currentInitialSurfaceSize()
      ),
      protectsPrimaryTab: pendingMount.protectsPrimaryTab
    )
  }

  private func restorePendingWorkspaceSnapshotIfNeeded() {
    guard let snapshot = pendingWorkspaceSnapshot else { return }
    pendingWorkspaceSnapshot = nil
    restoreWorkspaceSnapshot(snapshot)
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
        onActivatePanel: { [weak self] panel in
          self?.activateGhosttyPanel(panel)
        },
        onSelectTab: { [weak self] panel, tab in
          self?.selectGhosttyTab(tab, in: panel)
        },
        onClosePanel: { [weak self] panel in
          self?.closeGhosttyPanel(panel)
        },
        onCloseTab: { [weak self] panel, tab in
          self?.closeGhosttyTab(tab, in: panel)
        },
        onOpenTab: { [weak self] panel in
          self?.openShellTab(in: panel.id)
        }
      )
    )
    makeViewTransparent(host)
    mount(host)
    hostingView = host
  }

  private func mount(_ child: NSView) {
    makeViewTransparent(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    addSubview(child)
    NSLayoutConstraint.activate([
      child.leadingAnchor.constraint(equalTo: leadingAnchor),
      child.trailingAnchor.constraint(equalTo: trailingAnchor),
      child.topAnchor.constraint(equalTo: topAnchor),
      child.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  private func makeViewTransparent(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.layer?.isOpaque = false
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
    workingDirectory: String,
    initialSize: GhosttySurfaceInitialSize? = nil
  ) -> GhosttySurfaceConfiguration {
    GhosttySurfaceConfiguration(
      workingDirectory: workingDirectory,
      command: command,
      environment: environment,
      initialInput: initialInput,
      fontSize: resolvedFontSize(),
      initialSize: initialSize
    )
  }

  private func shellConfigurationForNewTerminal(in panelID: TerminalPanelID? = nil) -> GhosttySurfaceConfiguration {
    let sourceController = panelID
      .flatMap { terminalSession?.panel(for: $0)?.activeTab?.controller }
      ?? activeController
    let workingDirectory = sourceController?.workingDirectory
      ?? sourceController?.configuration.workingDirectory
      ?? resolvedProjectPath
    let launch = EmbeddedTerminalLaunchBuilder.shellLaunch(projectPath: workingDirectory)
    return makeGhosttyConfiguration(
      command: launch.ghosttyCommand,
      environment: launch.environment,
      initialInput: nil,
      workingDirectory: workingDirectory,
      initialSize: predictedInitialSizeForNewTerminal(in: panelID)
    )
  }

  private func shellConfiguration(
    forRestoredWorkingDirectory workingDirectory: String?,
    in panelID: TerminalPanelID? = nil
  ) -> GhosttySurfaceConfiguration {
    let restoredPath = resolvedExistingDirectory(workingDirectory)
    let launch = EmbeddedTerminalLaunchBuilder.shellLaunch(projectPath: restoredPath)
    return makeGhosttyConfiguration(
      command: launch.ghosttyCommand,
      environment: launch.environment,
      initialInput: nil,
      workingDirectory: restoredPath,
      initialSize: predictedInitialSizeForNewTerminal(in: panelID)
    )
  }

  private func currentInitialSurfaceSize() -> GhosttySurfaceInitialSize? {
    initialSurfaceSize(from: bounds.size)
  }

  private func predictedInitialSizeForNewTerminal(in panelID: TerminalPanelID? = nil) -> GhosttySurfaceInitialSize? {
    guard let terminalSession else {
      return currentInitialSurfaceSize()
    }

    if let panelID {
      if let size = terminalSession.panel(for: panelID)?.activeTab?.containerView.bounds.size,
         size.width > 0,
         size.height > 0 {
        return initialSurfaceSize(from: size)
      }
      return currentInitialSurfaceSize()
    }

    let newPanelID = TerminalPanelID()
    let projectedPanelIDs = terminalSession.visiblePanels.map(\.id) + [newPanelID]
    let projectedLayout = TerminalSplitLayout(axis: .horizontal, panelIDs: projectedPanelIDs)
    let frames = Self.panelFrames(
      for: projectedLayout.root,
      in: CGRect(origin: .zero, size: bounds.size)
    )

    guard let paneSize = frames[newPanelID]?.size else {
      return currentInitialSurfaceSize()
    }

    return initialSurfaceSize(
      from: Self.terminalContentSize(forPaneSize: paneSize, showsTabStrip: true)
    )
  }

  private func initialSurfaceSize(from size: CGSize) -> GhosttySurfaceInitialSize? {
    guard size.width > 0, size.height > 0 else { return nil }
    return GhosttySurfaceInitialSize(width: size.width, height: size.height)
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

  private func normalizedPanelSnapshots(
    _ panels: [TerminalWorkspacePanelSnapshot]
  ) -> [TerminalWorkspacePanelSnapshot] {
    let primary = panels.first { $0.role == .primary } ?? panels.first
    let auxiliaries = panels.filter { $0.role == .auxiliary }
    return ([primary].compactMap { $0 } + auxiliaries).prefix(4).map { $0 }
  }

  private func resetToPrimaryAgentTab(in terminalSession: TerminalSession) {
    for panel in terminalSession.auxiliaryPanels {
      requestClose(panel)
      _ = terminalSession.closePanel(panel.id)
    }

    for tab in terminalSession.primaryPanel.tabs where !isProtectedAgentTab(tab, in: terminalSession.primaryPanelID) {
      requestClose(tab)
      _ = terminalSession.closeTab(tab.id, in: terminalSession.primaryPanelID)
    }

    focusProtectedAgentTab()
  }

  private func restoreShellTabs(
    from panelSnapshot: TerminalWorkspacePanelSnapshot,
    in panelID: TerminalPanelID,
    existingTabIDs: [TerminalTabID],
    skippingFirstShellTab: Bool = false
  ) -> [TerminalTabID] {
    guard let terminalSession else { return existingTabIDs }
    var restoredTabIDs = existingTabIDs
    var hasSkippedFirstShellTab = false

    for tabSnapshot in panelSnapshot.tabs where tabSnapshot.role == .shell {
      if skippingFirstShellTab && !hasSkippedFirstShellTab {
        hasSkippedFirstShellTab = true
        continue
      }

      do {
        let tab = try terminalSession.openTab(
          in: panelID,
          named: restoredTabName(for: tabSnapshot),
          configuration: shellConfiguration(
            forRestoredWorkingDirectory: tabSnapshot.workingDirectory,
            in: panelID
          )
        )
        configureControllerHooks(for: tab.controller)
        restoredTabIDs.append(tab.id)
      } catch {
        AppLogger.session.error("Failed to restore Ghostty shell tab: \(error.localizedDescription)")
      }
    }

    return restoredTabIDs
  }

  private func restoreActiveSelection(
    from snapshot: TerminalWorkspaceSnapshot,
    panelIDs: [TerminalPanelID],
    tabIDs: [[TerminalTabID]]
  ) {
    guard let terminalSession else { return }
    guard !panelIDs.isEmpty else { return }

    let panelIndex = min(max(snapshot.activePanelIndex, 0), panelIDs.count - 1)
    let panelID = panelIDs[panelIndex]
    let savedPanel = snapshot.panels.indices.contains(panelIndex) ? snapshot.panels[panelIndex] : nil
    let savedActiveTabIndex = savedPanel?.activeTabIndex ?? 0
    let panelTabIDs = tabIDs.indices.contains(panelIndex) ? tabIDs[panelIndex] : []
    guard !panelTabIDs.isEmpty else {
      _ = terminalSession.focusPanel(panelID)
      return
    }

    let tabIndex = min(max(savedActiveTabIndex, 0), panelTabIDs.count - 1)
    _ = terminalSession.selectTab(panelTabIDs[tabIndex], in: panelID)
  }

  private func restoredTabName(for tab: TerminalWorkspaceTabSnapshot) -> String? {
    Self.nonEmpty(tab.name) ?? Self.nonEmpty(tab.title) ?? "Shell"
  }

  private func resolvedFontSize() -> Float {
    let fontSize = Float(UserDefaults.standard.double(forKey: AgentHubDefaults.terminalFontSize))
    return fontSize > 0 ? fontSize : 12
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private static func submitDelay(forByteCount count: Int) -> Duration {
    switch count {
    case ..<500:   return .milliseconds(100)
    case ..<2000:  return .milliseconds(250)
    default:       return .milliseconds(500)
    }
  }

  private func sendBracketedPasteText(
    _ text: String,
    to controller: GhosttyTerminalController?
  ) {
    controller?.sendBytes(TerminalPromptSubmissionPayload.bracketedPasteTextBytes(prompt: text))
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
      sendBracketedPasteText(fullText, to: protectedAgentController)
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
      if terminalSession?.focusPanel(direction: direction) == true {
        notifyWorkspaceChanged()
      }
    case .selectTab(let direction):
      if terminalSession?.selectTab(direction: direction) == true {
        notifyWorkspaceChanged()
      }
    }
  }

  private func openShellTab(in panelID: TerminalPanelID? = nil) {
    guard let terminalSession else { return }
    do {
      let tab = try terminalSession.openTab(
        in: panelID,
        named: "Shell",
        configuration: shellConfigurationForNewTerminal(in: panelID)
      )
      configureControllerHooks(for: tab.controller)
      notifyWorkspaceChanged()
    } catch {
      AppLogger.session.error("Failed to open Ghostty shell tab: \(error.localizedDescription)")
    }
  }

  private func openShellPane() {
    guard let terminalSession, terminalSession.canOpenPanel else { return }
    do {
      prepareVisiblePanelsForPaneTransition(
        projectedPanelIDs: terminalSession.visiblePanels.map(\.id) + [TerminalPanelID()]
      )
      let panel = try terminalSession.openPanel(
        named: "Shell",
        configuration: shellConfigurationForNewTerminal()
      )
      configureControllerHooks(for: panel.activeTab?.controller)
      notifyWorkspaceChanged()
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

  private func activateGhosttyPanel(_ panel: TerminalPanel) {
    guard let terminalSession else { return }
    if terminalSession.focusPanel(panel.id) {
      notifyWorkspaceChanged()
    }
  }

  private func selectGhosttyTab(_ tab: TerminalTab, in panel: TerminalPanel) {
    guard let terminalSession else { return }
    if terminalSession.selectTab(tab.id, in: panel.id) {
      notifyWorkspaceChanged()
    }
  }

  private func closeGhosttyPanel(_ panel: TerminalPanel) {
    guard let terminalSession, canCloseGhosttyPanel(panel) else { return }
    prepareVisiblePanelsForPaneTransition(
      projectedPanelIDs: terminalSession.visiblePanels.map(\.id).filter { $0 != panel.id }
    )
    requestClose(panel)
    if terminalSession.closePanel(panel.id) {
      notifyWorkspaceChanged()
    }
  }

  private func closeGhosttyTab(_ tab: TerminalTab, in panel: TerminalPanel) {
    guard let terminalSession, canCloseGhosttyTab(tab, in: panel) else { return }
    requestClose(tab)
    if terminalSession.closeTab(tab.id, in: panel.id) {
      notifyWorkspaceChanged()
    }
  }

  private func requestClose(_ panel: TerminalPanel) {
    for tab in panel.tabs {
      requestClose(tab)
    }
  }

  private func prepareVisiblePanelsForPaneTransition(projectedPanelIDs: [TerminalPanelID]) {
    guard let terminalSession, bounds.width > 0, bounds.height > 0 else { return }
    guard !projectedPanelIDs.isEmpty else { return }

    let layout = TerminalSplitLayout(axis: .horizontal, panelIDs: projectedPanelIDs)
    let frames = Self.panelFrames(
      for: layout.root,
      in: CGRect(origin: .zero, size: bounds.size)
    )

    for panel in terminalSession.visiblePanels {
      guard let paneSize = frames[panel.id]?.size else { continue }
      let contentSize = terminalContentSize(for: panel, paneSize: paneSize)
      panel.activeTab?.containerView.prepareForHostResize(to: contentSize)
    }
  }

  private func terminalContentSize(for panel: TerminalPanel, paneSize: CGSize) -> CGSize {
    Self.terminalContentSize(
      forPaneSize: paneSize,
      showsTabStrip: shouldShowTabStrip(for: panel)
    )
  }

  private func shouldShowTabStrip(for panel: TerminalPanel) -> Bool {
    panel.tabs.count > 1 || canCloseGhosttyPanel(panel)
  }

  private static func terminalContentSize(forPaneSize paneSize: CGSize, showsTabStrip: Bool) -> CGSize {
    CGSize(
      width: max(1, paneSize.width),
      height: max(1, paneSize.height - (showsTabStrip ? terminalTabStripHeight : 0))
    )
  }

  private static func panelFrames(
    for node: TerminalSplitLayout.Node,
    in rect: CGRect
  ) -> [TerminalPanelID: CGRect] {
    switch node {
    case .panel(let panelID):
      return [panelID: rect]
    case .split(let axis, let children):
      return splitPanelFrames(axis: axis, children: children, in: rect)
    }
  }

  private static func splitPanelFrames(
    axis: TerminalSplitAxis,
    children: [TerminalSplitLayout.Node],
    in rect: CGRect
  ) -> [TerminalPanelID: CGRect] {
    guard !children.isEmpty else { return [:] }

    var result: [TerminalPanelID: CGRect] = [:]
    let childCount = CGFloat(children.count)

    switch axis {
    case .horizontal:
      let totalDividerWidth = terminalPaneDividerSize * CGFloat(max(children.count - 1, 0))
      let childWidth = max(0, rect.width - totalDividerWidth) / childCount
      var nextX = rect.minX

      for (index, child) in children.enumerated() {
        if index > 0 {
          nextX += terminalPaneDividerSize
        }
        let childRect = CGRect(x: nextX, y: rect.minY, width: childWidth, height: rect.height)
        result.merge(
          panelFrames(for: child, in: childRect),
          uniquingKeysWith: { current, _ in current }
        )
        nextX += childWidth
      }

    case .vertical:
      let totalDividerHeight = terminalPaneDividerSize * CGFloat(max(children.count - 1, 0))
      let childHeight = max(0, rect.height - totalDividerHeight) / childCount
      var nextY = rect.minY

      for (index, child) in children.enumerated() {
        if index > 0 {
          nextY += terminalPaneDividerSize
        }
        let childRect = CGRect(x: rect.minX, y: nextY, width: rect.width, height: childHeight)
        result.merge(
          panelFrames(for: child, in: childRect),
          uniquingKeysWith: { current, _ in current }
        )
        nextY += childHeight
      }
    }

    return result
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
      self.notifyWorkspaceChanged()
    }
    controller.onCloseWindow = { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.closeControllerIfAllowed(controller)
    }
    controller.onStateChange = { [weak self] _ in
      self?.notifyWorkspaceChanged()
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
    if terminalSession.closeTab(located.tab.id, in: located.panel.id) {
      notifyWorkspaceChanged()
    }
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
      notifyWorkspaceChanged()
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

  private func notifyWorkspaceChanged() {
    guard !isRestoringWorkspace else { return }
    guard let snapshot = captureWorkspaceSnapshot() else { return }
    guard snapshot != lastWorkspaceSnapshot else { return }
    lastWorkspaceSnapshot = snapshot
    onWorkspaceChanged?(snapshot)
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
