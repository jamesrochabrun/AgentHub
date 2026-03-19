//
//  WebPreviewNavigationPolicy.swift
//  AgentHub
//
//  Centralized allowlist for embedded web preview navigation.
//

import Foundation

enum WebPreviewNavigationDecision: Equatable {
  case allow
  case openExternally(URL)
  case deny(String)
}

enum WebPreviewNavigationPolicy {

  static func decision(
    for navigationURL: URL?,
    allowedProjectRoot: URL?,
    isMainFrameNavigation: Bool,
    opensInNewWindow: Bool
  ) -> WebPreviewNavigationDecision {
    guard let navigationURL else { return .allow }

    guard isMainFrameNavigation || opensInNewWindow else {
      return .allow
    }

    if navigationURL.isFileURL {
      guard let allowedProjectRoot else {
        return .deny("Blocked file navigation because the preview has no allowed project root.")
      }

      return isURL(navigationURL, withinAllowedRoot: allowedProjectRoot)
        ? .allow
        : .deny("Blocked navigation outside the allowed project directory.")
    }

    if isAllowedLoopbackURL(navigationURL) {
      return .allow
    }

    return .openExternally(navigationURL)
  }

  static func isAllowedLoopbackURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = url.host?.lowercased() else {
      return false
    }

    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  static func isURL(_ url: URL, withinAllowedRoot rootURL: URL) -> Bool {
    let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let normalizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()

    if normalizedURL.path == normalizedRoot.path {
      return true
    }

    let rootPath = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
    return normalizedURL.path.hasPrefix(rootPath)
  }
}
