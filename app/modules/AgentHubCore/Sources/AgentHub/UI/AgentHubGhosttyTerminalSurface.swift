//
//  AgentHubGhosttyTerminalSurface.swift
//  AgentHub
//

import AppKit
import GhosttySwift
import SwiftUI

@MainActor
final class AgentHubGhosttyTerminalSurface: NSView, EmbeddedTerminalSurface {
  private var controller: GhosttyTerminalController?
  private var containerView: GhosttySwift.GhosttyTerminalContainerView?
  private var isConfigured = false
  private var hasDeliveredInitialPrompt = false
  private var hasPrefilledInitialInputText = false
  private var registeredPID: pid_t?
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
    controller?.foregroundProcessID
  }

  deinit {
    if let localEventMonitor {
      NSEvent.removeMonitor(localEventMonitor)
    }
    MainActor.assumeIsolated {
      controller?.requestClose()
      unregisterPID()
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
      mountGhostty(command: launch.ghosttyCommand, environment: launch.environment, initialInputText: initialInputText)
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
    mountGhostty(command: launch.ghosttyCommand, environment: launch.environment, initialInputText: nil)
  }

  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {
    terminateProcess()
    containerView?.removeFromSuperview()
    containerView = nil
    controller = nil
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
    controller?.requestClose()
    unregisterPID()
  }

  func resetPromptDeliveryFlag() {
    hasDeliveredInitialPrompt = false
  }

  func sendPromptIfNeeded(_ prompt: String) {
    guard !hasDeliveredInitialPrompt else { return }
    hasDeliveredInitialPrompt = true

    let planFeedbackPrefix = "\u{1B}[B\u{1B}[B\u{1B}[B\r"
    if prompt.hasPrefix(planFeedbackPrefix) {
      let feedback = String(prompt.dropFirst(planFeedbackPrefix.count))
      Task { @MainActor [weak self] in
        self?.controller?.sendArrowDownKey()
        try? await Task.sleep(for: .milliseconds(80))
        self?.controller?.sendArrowDownKey()
        try? await Task.sleep(for: .milliseconds(80))
        self?.controller?.sendArrowDownKey()
        try? await Task.sleep(for: .milliseconds(80))
        self?.controller?.sendReturnKey()
        try? await Task.sleep(for: .milliseconds(150))
        if !feedback.isEmpty {
          self?.controller?.sendText(feedback)
          try? await Task.sleep(for: .milliseconds(100))
        }
        self?.controller?.sendReturnKey()
      }
      return
    }

    controller?.sendText(prompt)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      self?.controller?.sendReturnKey()
    }
  }

  func submitPromptImmediately(_ prompt: String) -> Bool {
    guard controller != nil else { return false }
    controller?.sendText(prompt)
    let delay = Self.submitDelay(forByteCount: prompt.utf8.count)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      self?.controller?.sendReturnKey()
    }
    return true
  }

  func typeText(_ text: String) {
    controller?.sendText(text)
  }

  func typeInitialTextIfNeeded(_ text: String) {
    guard !text.isEmpty else { return }
    guard !hasPrefilledInitialInputText else { return }
    hasPrefilledInitialInputText = true
    typeText(text)
  }

  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {
    // Ghostty owns live appearance through its config. Font size is applied at surface creation.
  }

  func focus() {
    controller?.focusTerminal()
  }

  private func mountGhostty(command: String, environment: [String: String], initialInputText: String?) {
    do {
      let fontSize = Float(UserDefaults.standard.double(forKey: AgentHubDefaults.terminalFontSize))
      let resolvedFontSize = fontSize > 0 ? fontSize : 12
      let controller = try GhosttyTerminalController(
        configuration: GhosttySurfaceConfiguration(
          workingDirectory: projectPath.isEmpty ? NSHomeDirectory() : projectPath,
          command: command,
          environment: environment,
          initialInput: initialInputText,
          fontSize: resolvedFontSize
        )
      )
      controller.onClose = { [weak self] _ in
        self?.unregisterPID()
      }
      controller.onOpenURL = { [weak self] url in
        self?.handleOpenURL(url) ?? false
      }
      let container = try GhosttySwift.GhosttyTerminalContainerView(controller: controller)
      mount(container)
      self.controller = controller
      self.containerView = container
      installInteractionMonitorIfNeeded()
      registerPIDWhenAvailable()
    } catch {
      mountError(error.localizedDescription)
    }
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

  private func mountError(_ message: String) {
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
      guard let self, let surfaceView = self.containerView?.surfaceView else { return event }

      switch event.type {
      case .keyDown:
        guard let window = surfaceView.window, event.window === window else { break }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isTerminalVisible = surfaceView.superview != nil && !surfaceView.isHidden && surfaceView.alphaValue > 0

        if isTerminalVisible,
           self.isTerminalResponderActive(window: window, terminal: surfaceView),
           flags == .control,
           event.keyCode == 50,
           self.onRequestShowEditor != nil {
          self.onRequestShowEditor?()
          self.onUserInteraction?()
          return nil
        }

        if isTerminalVisible,
           self.isTerminalResponderActive(window: window, terminal: surfaceView),
           flags == .command,
           event.charactersIgnoringModifiers == "f" {
          _ = self.controller?.performBindingAction("search:")
          self.onUserInteraction?()
          return nil
        }

        guard isTerminalResponderActive(window: window, terminal: surfaceView) else { break }

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
          queuedContextPrompt = self.consumeQueuedWebPreviewContextOnSubmit?()
        case .passthrough, .newline:
          queuedContextPrompt = nil
        }

        switch TerminalSubmitInterception.dispatch(for: action, queuedContextPrompt: queuedContextPrompt) {
        case .passthrough:
          self.onUserInteraction?()
        case .newline:
          self.controller?.sendText("\n")
          self.onUserInteraction?()
          return nil
        case .submit:
          self.controller?.sendReturnKey()
          self.onUserInteraction?()
          return nil
        case .appendContextAndSubmit(let queuedContextPrompt):
          let fullText = "\n\n\(queuedContextPrompt)"
          self.controller?.sendText(fullText)
          let delay = Self.submitDelay(forByteCount: fullText.utf8.count)
          Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.controller?.sendReturnKey()
          }
          self.onUserInteraction?()
          return nil
        }
      case .leftMouseUp:
        guard let window = surfaceView.window, event.window === window else { return event }
        let locationInTerminal = surfaceView.convert(event.locationInWindow, from: nil)
        if surfaceView.bounds.contains(locationInTerminal) {
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

  private func registerPIDWhenAvailable() {
    Task { @MainActor [weak self] in
      for _ in 0..<10 {
        guard let self else { return }
        if let pid = self.currentProcessPID, pid > 0 {
          self.registeredPID = pid
          TerminalProcessRegistry.shared.register(pid: pid)
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func unregisterPID() {
    if let registeredPID {
      TerminalProcessRegistry.shared.unregister(pid: registeredPID)
      self.registeredPID = nil
    }
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
