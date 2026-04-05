//
//  WebPreviewExternalFailureDecision.swift
//  AgentHub
//
//  Describes how the preview should react when an external localhost server
//  fails to load.
//

import Foundation

enum WebPreviewExternalFailureDecision: Equatable {
  case ignore
  case recoverToFallback
  case showDisconnected
}
