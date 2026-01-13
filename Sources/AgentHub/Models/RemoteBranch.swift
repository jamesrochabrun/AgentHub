//
//  RemoteBranch.swift
//  AgentHub
//
//  Created by Assistant on 1/12/26.
//

import Foundation

/// Represents a remote git branch
public struct RemoteBranch: Identifiable, Hashable, Sendable {
  public var id: String { name }

  /// Full branch name (e.g., "origin/feature-auth")
  public let name: String

  /// Remote name (e.g., "origin")
  public let remote: String

  /// Display name without remote prefix (e.g., "feature-auth")
  public var displayName: String {
    name.hasPrefix("\(remote)/") ? String(name.dropFirst(remote.count + 1)) : name
  }

  public init(name: String, remote: String) {
    self.name = name
    self.remote = remote
  }
}
