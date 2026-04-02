//
//  WebPreviewScrollRestorationCoordinator.swift
//  AgentHub
//
//  Coordinates app-triggered web preview reloads so scroll position can be
//  captured before reload and restored after navigation completes.
//

import Foundation

struct WebPreviewScrollRestorationCoordinator: Equatable {
  private(set) var effectiveReloadToken: UUID?
  private(set) var pendingRequestedReloadToken: UUID?
  private(set) var pendingScrollPosition: WebPreviewScrollPosition?
  private(set) var isCapturingScrollPosition = false
  private(set) var suppressesSelectorRestore = false

  mutating func reset(to token: UUID?) {
    effectiveReloadToken = token
    pendingRequestedReloadToken = nil
    pendingScrollPosition = nil
    isCapturingScrollPosition = false
    suppressesSelectorRestore = false
  }

  mutating func queueReload(token: UUID?) {
    guard let token, token != effectiveReloadToken else {
      return
    }

    pendingRequestedReloadToken = token
  }

  mutating func beginCaptureIfNeeded() -> Bool {
    guard let pendingRequestedReloadToken else { return false }
    guard pendingRequestedReloadToken != effectiveReloadToken else {
      self.pendingRequestedReloadToken = nil
      return false
    }
    guard !isCapturingScrollPosition else { return false }

    isCapturingScrollPosition = true
    return true
  }

  @discardableResult
  mutating func finishCapture(with scrollPosition: WebPreviewScrollPosition?) -> UUID? {
    guard isCapturingScrollPosition else { return nil }

    isCapturingScrollPosition = false
    guard let pendingRequestedReloadToken,
          pendingRequestedReloadToken != effectiveReloadToken else {
      self.pendingRequestedReloadToken = nil
      pendingScrollPosition = nil
      return nil
    }

    effectiveReloadToken = pendingRequestedReloadToken
    self.pendingRequestedReloadToken = nil
    pendingScrollPosition = scrollPosition
    suppressesSelectorRestore = true
    return effectiveReloadToken
  }

  mutating func consumePendingScrollPosition() -> WebPreviewScrollPosition? {
    suppressesSelectorRestore = false
    defer { pendingScrollPosition = nil }
    return pendingScrollPosition
  }
}
