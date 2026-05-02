//
//  TerminalPanelActivityBannerHostingView.swift
//  AgentHub
//

import SwiftUI

final class TerminalPanelActivityBannerHostingView: NSHostingView<TerminalPanelActivityBanner> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
