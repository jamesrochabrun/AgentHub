//
//  TweakWorkspaceError.swift
//  AgentHub
//

import Foundation

enum TweakWorkspaceError: LocalizedError {
  case missingTarget
  case unsupportedTarget
  case invalidGeneratedTweaks

  var errorDescription: String? {
    switch self {
    case .missingTarget:
      return "The preview file is no longer available."
    case .unsupportedTarget:
      return "Tweaks can only be added to a regular design file."
    case .invalidGeneratedTweaks:
      return "The generated update did not preserve the existing tweak controls. No changes were applied."
    }
  }
}
