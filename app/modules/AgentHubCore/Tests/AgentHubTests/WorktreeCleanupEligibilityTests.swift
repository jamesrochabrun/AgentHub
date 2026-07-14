import AgentHubGitHub
import Testing

@testable import AgentHubCore

@Suite("Worktree cleanup eligibility")
struct WorktreeCleanupEligibilityTests {
  @Test("Suggests cleanup only for safe merged worktree sessions")
  func suggestsCleanupForSafeMergedWorktree() {
    #expect(WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: true,
      isPendingSession: false,
      isSessionActive: false,
      sessionStatus: .idle,
      pullRequestState: .merged,
      ciStatus: .success
    ))
    #expect(WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: true,
      isPendingSession: false,
      isSessionActive: false,
      sessionStatus: .waitingForUser,
      pullRequestState: .merged,
      ciStatus: .none
    ))
  }

  @Test("Suppresses cleanup while the worktree may still be in use")
  func suppressesUnsafeCleanupSuggestions() {
    let safeArguments = (
      isWorktree: true,
      isPendingSession: false,
      isSessionActive: false,
      sessionStatus: SessionStatus?.some(.idle),
      pullRequestState: GitHubPullRequestState?.some(.merged),
      ciStatus: CIStatus.success
    )

    #expect(!WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: false,
      isPendingSession: safeArguments.isPendingSession,
      isSessionActive: safeArguments.isSessionActive,
      sessionStatus: safeArguments.sessionStatus,
      pullRequestState: safeArguments.pullRequestState,
      ciStatus: safeArguments.ciStatus
    ))
    #expect(!WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: safeArguments.isWorktree,
      isPendingSession: true,
      isSessionActive: safeArguments.isSessionActive,
      sessionStatus: safeArguments.sessionStatus,
      pullRequestState: safeArguments.pullRequestState,
      ciStatus: safeArguments.ciStatus
    ))
    #expect(!WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: safeArguments.isWorktree,
      isPendingSession: safeArguments.isPendingSession,
      isSessionActive: true,
      sessionStatus: safeArguments.sessionStatus,
      pullRequestState: safeArguments.pullRequestState,
      ciStatus: safeArguments.ciStatus
    ))
    #expect(!WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: safeArguments.isWorktree,
      isPendingSession: safeArguments.isPendingSession,
      isSessionActive: safeArguments.isSessionActive,
      sessionStatus: .awaitingApproval(tool: "Bash"),
      pullRequestState: safeArguments.pullRequestState,
      ciStatus: safeArguments.ciStatus
    ))
    #expect(!WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: safeArguments.isWorktree,
      isPendingSession: safeArguments.isPendingSession,
      isSessionActive: safeArguments.isSessionActive,
      sessionStatus: safeArguments.sessionStatus,
      pullRequestState: .open,
      ciStatus: safeArguments.ciStatus
    ))
    #expect(!WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: safeArguments.isWorktree,
      isPendingSession: safeArguments.isPendingSession,
      isSessionActive: safeArguments.isSessionActive,
      sessionStatus: safeArguments.sessionStatus,
      pullRequestState: safeArguments.pullRequestState,
      ciStatus: .failure
    ))
    #expect(!WorktreeCleanupEligibility.shouldSuggestCleanup(
      isWorktree: safeArguments.isWorktree,
      isPendingSession: safeArguments.isPendingSession,
      isSessionActive: safeArguments.isSessionActive,
      sessionStatus: safeArguments.sessionStatus,
      pullRequestState: safeArguments.pullRequestState,
      ciStatus: .pending
    ))
  }
}
