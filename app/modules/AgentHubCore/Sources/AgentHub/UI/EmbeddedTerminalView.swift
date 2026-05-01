//
//  EmbeddedTerminalView.swift
//  AgentHub
//

import AgentHubTerminalUI
import SwiftUI

/// SwiftUI wrapper that adapts AgentHub app state to an embedded terminal surface.
public struct EmbeddedTerminalView: NSViewRepresentable {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @AppStorage(TerminalUserDefaultsKeys.terminalFontSize) private var terminalFontSize: Double = 12
  @AppStorage(TerminalUserDefaultsKeys.terminalFontFamily) private var terminalFontFamily: String = "SF Mono"

  let terminalKey: String
  let sessionId: String?
  let projectPath: String
  let cliConfiguration: CLICommandConfiguration
  let initialPrompt: String?
  let initialInputText: String?
  let viewModel: CLISessionsViewModel?
  let dangerouslySkipPermissions: Bool
  let permissionModePlan: Bool
  let worktreeName: String?
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
    let terminal = resolveTerminal(context: context, isDark: colorScheme == .dark)
    applyCallbacks(to: terminal)
    hostView.mount(terminal, key: terminalKey)
    return hostView
  }

  public func updateNSView(_ nsView: EmbeddedTerminalHostView, context: Context) {
    let terminal = resolveTerminal(context: context, isDark: colorScheme == .dark)
    applyCallbacks(to: terminal)
    nsView.mount(terminal, key: terminalKey)
    terminal.syncAppearance(
      isDark: colorScheme == .dark,
      fontSize: CGFloat(terminalFontSize),
      fontFamily: terminalFontFamily,
      theme: runtimeTheme.map(TerminalAppearanceTheme.init)
    )

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
      configureFileOpenRouting(for: terminal)
      return terminal
    }

    if let existing = context.coordinator.standaloneTerminal {
      return existing
    }

    let factory = agentHub?.terminalSurfaceFactory ?? DefaultEmbeddedTerminalSurfaceFactory()
    let terminal = factory.makeSurface(for: .storedPreference)
    terminal.updateContext(terminalSessionKey: terminalKey)
    terminal.configure(
      launch: EmbeddedTerminalLaunchBuilder.cliLaunch(
        sessionId: sessionId,
        projectPath: projectPath,
        cliConfiguration: cliConfiguration,
        initialPrompt: initialPrompt,
        dangerouslySkipPermissions: dangerouslySkipPermissions,
        permissionModePlan: permissionModePlan,
        worktreeName: worktreeName,
        metadataStore: agentHub?.metadataStore
      ),
      projectPath: projectPath,
      initialInputText: initialInputText,
      isDark: isDark
    )
    configureFileOpenRouting(for: terminal)
    context.coordinator.standaloneTerminal = terminal
    return terminal
  }

  private func applyCallbacks(to terminal: any EmbeddedTerminalSurface) {
    terminal.onUserInteraction = onUserInteraction
    terminal.onRequestShowEditor = onRequestShowEditor
    terminal.consumeQueuedWebPreviewContextOnSubmit = consumeQueuedWebPreviewContextOnSubmit
  }

  private func configureFileOpenRouting(for terminal: any EmbeddedTerminalSurface) {
    terminal.updateContext(terminalSessionKey: terminalKey)
    terminal.onOpenFile = { [weak viewModel] path, line in
      viewModel?.pendingFileOpen = (sessionId: terminalKey, filePath: path, lineNumber: line)
    }
  }
}

extension TerminalAppearanceTheme {
  init(_ runtimeTheme: RuntimeTheme) {
    self.init(
      id: runtimeTheme.id,
      terminalBackground: runtimeTheme.terminalBackground,
      terminalForeground: runtimeTheme.terminalForeground,
      terminalCursor: runtimeTheme.terminalCursor
    )
  }
}
