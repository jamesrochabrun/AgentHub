//
//  RemoteBranch.swift
//  AgentHub
//
//  Created by Assistant on 1/12/26.
//

import Foundation

/// Represents a git branch that can be used as a worktree start point.
public struct RemoteBranch: Identifiable, Hashable, Sendable {
  public var id: String { "\(remote):\(name)" }

  /// Full branch name (e.g., "main" or "origin/main")
  public let name: String

  /// Source name (e.g., "local" or "origin")
  public let remote: String

  /// Display name without remote prefix (e.g., "feature-auth")
  public var displayName: String {
    name.hasPrefix("\(remote)/") ? String(name.dropFirst(remote.count + 1)) : name
  }

  public var isRemote: Bool {
    remote != "local"
  }

  public var gitStartPoint: String {
    name
  }

  public var pickerDisplayName: String {
    isRemote ? "\(name) (latest remote)" : displayName
  }

  public var startPointDescription: String {
    isRemote ? "latest fetched \(name)" : "local branch '\(displayName)'"
  }

  public init(name: String, remote: String) {
    self.name = name
    self.remote = remote
  }

  public static func worktreeBaseOptions(
    localBranches: [RemoteBranch],
    remoteDefaultBranch: RemoteBranch?
  ) -> [RemoteBranch] {
    guard let remoteDefaultBranch else { return localBranches }
    guard !localBranches.contains(remoteDefaultBranch) else { return localBranches }
    return [remoteDefaultBranch] + localBranches
  }
}
