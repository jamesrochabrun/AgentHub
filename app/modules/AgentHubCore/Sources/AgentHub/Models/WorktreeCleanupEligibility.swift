//
//  WorktreeCleanupEligibility.swift
//  AgentHub
//

import AgentHubGitHub

public enum WorktreeCleanupEligibility {
  public static func shouldSuggestCleanup(
    isWorktree: Bool,
    isPendingSession: Bool,
    isSessionActive: Bool,
    sessionStatus: SessionStatus?,
    pullRequestState: GitHubPullRequestState?,
    ciStatus: CIStatus
  ) -> Bool {
    guard isWorktree,
          !isPendingSession,
          !isSessionActive,
          pullRequestState == .merged,
          ciStatus != .failure,
          ciStatus != .pending else {
      return false
    }

    switch sessionStatus {
    case .thinking, .executingTool, .awaitingApproval:
      return false
    case .waitingForUser, .idle, nil:
      return true
    }
  }
}
