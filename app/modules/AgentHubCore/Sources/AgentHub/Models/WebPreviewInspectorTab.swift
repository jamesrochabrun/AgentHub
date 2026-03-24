//
//  WebPreviewInspectorTab.swift
//  AgentHub
//
//  Tabs available in the web preview inspector rail.
//

import Foundation

enum WebPreviewInspectorTab: String, CaseIterable, Equatable, Sendable {
  case design
  case code

  var title: String {
    switch self {
    case .design:
      "Design"
    case .code:
      "Code"
    }
  }
}
