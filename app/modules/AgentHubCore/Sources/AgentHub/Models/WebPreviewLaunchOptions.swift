//
//  WebPreviewLaunchOptions.swift
//  AgentHub
//
//  Describes the explicit choices AgentHub can offer when preview is opened
//  before a live localhost URL is available for the session.
//

import Foundation

struct WebPreviewLaunchOptions: Equatable {
  let staticPreviewResolution: WebPreviewResolution
  let canAskAgent: Bool

  var hasStaticFallback: Bool {
    if case .directFile = staticPreviewResolution {
      return true
    }
    return false
  }
}
