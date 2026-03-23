//
//  WebPreviewExternalLoadFailurePolicy.swift
//  AgentHub
//
//  Decides when an external localhost preview failure should force a fallback
//  to static HTML versus being ignored as part of normal web view reloads/HMR.
//

import Foundation

enum WebPreviewExternalLoadFailurePolicy {
  static func shouldFallback(
    hasLoadedExternalContent: Bool,
    error: String
  ) -> Bool {
    guard !isIgnorable(error: error) else {
      return false
    }

    return !hasLoadedExternalContent
  }

  private static func isIgnorable(error: String) -> Bool {
    let normalizedError = error.lowercased()

    return normalizedError.contains("cancelled")
      || normalizedError.contains("canceled")
      || normalizedError.contains("frame load interrupted")
      || normalizedError.contains("webkiterrordomain error 102")
  }
}
