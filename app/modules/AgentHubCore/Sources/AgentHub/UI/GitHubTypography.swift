//
//  GitHubTypography.swift
//  AgentHub
//
//  Shared typography tokens for GitHub UI surfaces.
//

import SwiftUI

enum GitHubTypography {
  static let panelTitle = Font.heading
  static let sectionTitle = Font.secondaryLarge
  static let sectionLabel = Font.geist(size: 11, weight: .semibold)
  static let button = Font.geist(size: 11, weight: .medium)
  static let body = Font.secondaryDefault
  static let bodySmall = Font.secondarySmall
  static let caption = Font.secondaryCaption
  static let badge = Font.geist(size: 10, weight: .medium)
  static let monoTitle = Font.jetBrainsMono(size: 13, weight: .bold)
  static let monoStrong = Font.jetBrainsMono(size: 11, weight: .semibold)
  static let monoBody = Font.primarySmall
  static let monoCaption = Font.primaryCaption
}
