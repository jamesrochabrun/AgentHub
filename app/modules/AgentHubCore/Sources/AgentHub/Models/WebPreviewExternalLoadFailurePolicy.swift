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
    // Real connection failures always force a fallback, even on a second
    // load — otherwise a server that dies mid-session leaves the user
    // staring at a stale render with no feedback.
    if isConnectionRefused(error: error) {
      return true
    }

    guard !isIgnorable(error: error) else {
      return false
    }

    return !hasLoadedExternalContent
  }

  static func shouldFallbackForManagedPreview(error: String) -> Bool {
    if isConnectionRefused(error: error) {
      return true
    }

    return !isIgnorable(error: error)
  }

  private static func isIgnorable(error: String) -> Bool {
    let normalizedError = error.lowercased()

    return normalizedError.contains("cancelled")
      || normalizedError.contains("canceled")
      || normalizedError.contains("frame load interrupted")
      || normalizedError.contains("webkiterrordomain error 102")
  }

  private static func isConnectionRefused(error: String) -> Bool {
    let normalizedError = error.lowercased()

    return normalizedError.contains("connection refused")
      || normalizedError.contains("could not connect to the server")
      || normalizedError.contains("nsurlerrorcannotconnecttohost")
      || normalizedError.contains("nsurlerrorcannotfindhost")
      || normalizedError.contains("a server with the specified hostname could not be found")
  }
}
