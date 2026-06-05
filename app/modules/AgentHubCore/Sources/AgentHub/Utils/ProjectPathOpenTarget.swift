//
//  ProjectPathOpenTarget.swift
//  AgentHub
//
//  Targets for opening a project folder from monitoring card path menus.
//

import AppKit
import Foundation

enum ProjectPathOpenTarget: String, CaseIterable, Identifiable {
  case finder
  case cursor
  case visualStudioCode
  case sublimeText
  case xcode
  case ghostty
  case terminal

  var id: String { rawValue }

  var label: String {
    switch self {
    case .finder: return "Finder"
    case .cursor: return "Cursor"
    case .visualStudioCode: return "VS Code"
    case .sublimeText: return "Sublime Text"
    case .xcode: return "Xcode"
    case .ghostty: return "Ghostty"
    case .terminal: return "Terminal"
    }
  }

  var bundleIdentifier: String {
    bundleIdentifiers[0]
  }

  var bundleIdentifiers: [String] {
    switch self {
    case .finder: return ["com.apple.finder"]
    case .cursor: return ["com.todesktop.230313mzl4w4u92"]
    case .visualStudioCode: return ["com.microsoft.VSCode"]
    case .sublimeText: return ["com.sublimetext.4", "com.sublimetext.3"]
    case .xcode: return ["com.apple.dt.Xcode"]
    case .ghostty: return ["com.mitchellh.ghostty"]
    case .terminal: return ["com.apple.Terminal"]
    }
  }

  var isInstalled: Bool {
    isInstalled { bundleIdentifier in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
  }

  func isInstalled(applicationURL: (String) -> URL?) -> Bool {
    resolvedApplicationURL(applicationURL: applicationURL) != nil
  }

  func open(path: String) {
    if self == .finder {
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
      return
    }

    guard let applicationURL = resolvedApplicationURL(applicationURL: { bundleIdentifier in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }) else {
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path, isDirectory: true)],
      withApplicationAt: applicationURL,
      configuration: configuration
    )
  }

  static func copyPath(_ path: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(path, forType: .string)
  }

  private func resolvedApplicationURL(applicationURL: (String) -> URL?) -> URL? {
    for bundleIdentifier in bundleIdentifiers {
      if let url = applicationURL(bundleIdentifier) {
        return url
      }
    }
    return nil
  }
}
