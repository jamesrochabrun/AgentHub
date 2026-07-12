//
//  TweakWorkspaceTransaction.swift
//  AgentHub
//

import Foundation

struct TweakWorkspaceTransaction: Sendable {
  let rootURL: URL
  let workingFileURL: URL
  let targetFileURL: URL
  let baseContents: Data
}
