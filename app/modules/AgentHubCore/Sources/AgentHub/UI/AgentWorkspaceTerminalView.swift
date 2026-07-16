//
//  AgentWorkspaceTerminalView.swift
//  AgentHub
//

import AppKit
import SwiftUI

public struct AgentWorkspaceTerminalView: NSViewRepresentable {
  let workspaceID: String
  let viewModel: AgentWorkspacesViewModel
  let isDark: Bool
  let fontSize: Double
  let fontFamily: String
  let theme: RuntimeTheme?

  public init(
    workspaceID: String,
    viewModel: AgentWorkspacesViewModel,
    isDark: Bool,
    fontSize: Double,
    fontFamily: String,
    theme: RuntimeTheme?
  ) {
    self.workspaceID = workspaceID
    self.viewModel = viewModel
    self.isDark = isDark
    self.fontSize = fontSize
    self.fontFamily = fontFamily
    self.theme = theme
  }

  public func makeNSView(context: Context) -> NSView {
    guard let surface = viewModel.terminalSurface(
      for: workspaceID,
      isDark: isDark
    ) else {
      let label = NSTextField(labelWithString: "Workspace unavailable")
      label.alignment = .center
      label.textColor = .secondaryLabelColor
      return label
    }
    surface.syncAppearance(
      isDark: isDark,
      fontSize: fontSize,
      fontFamily: fontFamily,
      theme: theme
    )
    return surface.view
  }

  public func updateNSView(_ nsView: NSView, context: Context) {
    viewModel.terminalSurface(for: workspaceID, isDark: isDark)?.syncAppearance(
      isDark: isDark,
      fontSize: fontSize,
      fontFamily: fontFamily,
      theme: theme
    )
  }
}
