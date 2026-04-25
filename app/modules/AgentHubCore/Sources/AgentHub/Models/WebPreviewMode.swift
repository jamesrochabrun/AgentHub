//
//  WebPreviewMode.swift
//  AgentHub
//
//  Routing source-of-truth for the web preview pane: which dev server
//  the pane is currently looking at.
//

import Foundation

/// Which server the web preview pane is rendering.
///
/// Projects can run multiple dev servers concurrently (e.g. Vite at :5173
/// and Storybook at :6006). The preview pane always shows exactly one;
/// `WebPreviewMode` identifies which.
public enum WebPreviewMode: String, Sendable, Equatable {
  /// Primary application dev server (Vite, Next, CRA, Astro, etc.).
  /// Auto-detected from `package.json`. Honors agent-advertised localhost URLs.
  case app
  /// Storybook component catalog. Compound key `"{sessionId}:storybook"` in
  /// `DevServerManager`; ignores agent-advertised URLs (which target the app server).
  case storybook

  /// Returns the `DevServerManager` key for this mode.
  /// `.app` keys by plain session ID so it matches the agent's primary server.
  /// `.storybook` uses a compound key so it coexists with the app server.
  public func serverKey(for sessionId: String) -> String {
    switch self {
    case .app: return sessionId
    case .storybook: return "\(sessionId):storybook"
    }
  }
}
