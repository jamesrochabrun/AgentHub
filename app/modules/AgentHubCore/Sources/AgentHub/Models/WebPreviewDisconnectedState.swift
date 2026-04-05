//
//  WebPreviewDisconnectedState.swift
//  AgentHub
//
//  Captures the state shown when an external localhost preview was loaded
//  successfully once, then became unreachable.
//

import Foundation

struct WebPreviewDisconnectedState: Equatable {
  let url: URL
  let error: String
  let staticPreviewResolution: WebPreviewResolution

  var hasStaticFallback: Bool {
    if case .directFile = staticPreviewResolution {
      return true
    }
    return false
  }
}
