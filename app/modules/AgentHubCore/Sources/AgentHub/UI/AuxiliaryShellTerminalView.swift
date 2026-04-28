//
//  AuxiliaryShellTerminalView.swift
//  AgentHub
//

import SwiftUI

public struct AuxiliaryShellTerminalView: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @AppStorage(AgentHubDefaults.terminalFontSize) private var terminalFontSize: Double = 12
  @AppStorage(AgentHubDefaults.terminalFontFamily) private var terminalFontFamily: String = "SF Mono"

  let terminalKey: String
  let projectPath: String
  let viewModel: CLISessionsViewModel

  public init(
    terminalKey: String,
    projectPath: String,
    viewModel: CLISessionsViewModel
  ) {
    self.terminalKey = terminalKey
    self.projectPath = projectPath
    self.viewModel = viewModel
  }

  public func makeNSView(context: Context) -> AuxiliaryShellTerminalHostView {
    let hostView = AuxiliaryShellTerminalHostView()
    hostView.mount(
      resolveTerminal(),
      key: terminalKey
    )
    return hostView
  }

  public func updateNSView(_ nsView: AuxiliaryShellTerminalHostView, context: Context) {
    let terminal = resolveTerminal()
    nsView.mount(terminal, key: terminalKey)
    terminal.syncAppearance(isDark: colorScheme == .dark, fontSize: CGFloat(terminalFontSize), fontFamily: terminalFontFamily, theme: runtimeTheme)
  }

  public static func dismantleNSView(_ nsView: AuxiliaryShellTerminalHostView, coordinator: ()) {
    nsView.unmountTerminal()
  }

  private func resolveTerminal() -> any EmbeddedTerminalSurface {
    viewModel.getOrCreateAuxiliaryShellTerminal(
      forKey: terminalKey,
      projectPath: projectPath,
      isDark: colorScheme == .dark
    )
  }
}
