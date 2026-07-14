# GitHub PR/CI Monitor

AgentHub observes GitHub pull request state and CI checks through a shared service in the `AgentHubGitHub` module. The goal is to let multiple UI surfaces show current PR/check state without each surface starting its own `gh` polling loop.

## User Behavior

- GitHub monitoring is optional and only works when the GitHub CLI (`gh`) is installed, authenticated, and the session project is a GitHub repository.
- Session rows show GitHub status only when the current session branch has a pull request. Branches with no PR stay visually quiet.
- When a PR exists, the side-panel session row shows a compact bottom line with PR state and CI summary, for example `Draft PR #20 - CI passing 1/1`.
- CI failures, requested changes, and merge conflicts are in-app attention states. They affect compact row styling and idle-session ordering, but do not produce macOS notifications.
- If a refresh fails after a PR has been observed, the row keeps safe last-known data and marks it unavailable instead of replacing useful state with an empty result.
- Monitoring cards can expose the current branch PR as quick access.
- The GitHub panel observes the current branch PR and the selected PR detail/check state.
- The side panel refresh button forces a refresh for the visible session branch targets.

## Architecture

The shared service is `GitHubPRObservationService`, an actor that implements `GitHubPRObservationServiceProtocol`.

Core types:

- `GitHubPRObservationTarget`
  - `.session(projectPath:branchName:linkedPullRequests:)`
  - `.pullRequest(projectPath:number:)`
- `GitHubPRObservationSnapshot`
  - target
  - optional pull request
  - check runs
  - derived `GitHubCISummary`
  - derived blockers
  - observation state
  - last successful full refresh date and stale-state flag
- `GitHubPRObservationState`
  - `.idle`
  - `.refreshing`
  - `.ready`
  - `.error(String)`
  - `.paused(String)`

The service is injected from `AgentHubProvider` as `gitHubPRObservationService`, alongside the regular `gitHubService`.

Consumers subscribe with `AsyncStream<GitHubPRObservationSnapshot>`. Subscriptions are keyed by target, so multiple surfaces watching the same repository branch or PR share one fetch/poll loop.

## Data Flow

```
SwiftUI surface
  -> SessionGitHubQuickAccessViewModel or GitHubViewModel
  -> GitHubPRObservationService.subscribe(...)
  -> GitHubCLIService
  -> gh CLI
  -> GitHubPRObservationSnapshot
  -> SwiftUI state update
```

For session targets, the service resolves the local repository identity from its GitHub remotes, then:

1. Uses the newest detected PR link only when its `owner/repository` matches the local repository.
2. Otherwise asks `gh` for the exact supplied session branch, rather than relying on the worktree's currently checked-out branch.

The normal refresh path is one `gh pr view` call. PR metadata includes `statusCheckRollup`, workflow names, timestamps, and the head commit OID. `getChecks(prNumber:at:)` is a compatibility fallback only when GitHub omits the rollup field entirely.

Fallback check data is retained only when it belongs to the same non-nil head commit OID. A new head never inherits checks from an older commit. `lastRefreshedAt` advances only after a complete successful refresh, so unavailable/stale UI is truthful.

`GitHubCLIService.getCurrentBranchPR(branchName:at:)` treats GitHub CLI's "no pull requests found for branch ..." response as a valid no-PR result, not as a UI error.

## Polling And Performance

Default observation configuration:

- Pending checks: refresh every 30 seconds while active and every 120 seconds while idle, for at most one hour from discovery
- Settled PR checks: refresh every 120 seconds while active, then stop after 5 minutes without activity
- Merged or closed PRs: stop automatic observation immediately after the terminal state is observed; retain the cached state and allow manual refresh
- No discovered PR: retry discovery for up to 10 minutes after activity, then stop
- Transient error backoff: 60 seconds, 120 seconds, then 300 seconds
- Global GitHub refresh concurrency: at most two `gh` operations
- Inactive target cache retention: 15 minutes

Performance rules:

- The service only polls targets with active subscribers.
- Unsubscribing the last subscriber cancels the scheduled polling task for that target.
- Multiple subscribers for the same target share one snapshot and one scheduled refresh.
- Manual refresh is awaited and prioritized over queued automatic refreshes. Concurrent requests for the same target are coalesced.
- A manual refresh without subscribers performs one fetch and populates the cache without starting a background polling loop.
- Session activity extends the adaptive polling window but does not force an immediate network refresh for every event.
- Terminal setup errors (`gh` missing, unauthenticated, not a git repository, no remote) pause automatic polling until new activity or a manual refresh reactivates the target.
- Session row subscriptions can opt out of immediate fetches with `refreshOnSubscribe: false`; activity timestamps decide whether observation should start.
- Initial sidebar refresh is delayed until after launch and limited to a small batch so GitHub state does not block app startup.
- Repository remote resolution is a cached local `git remote -v` read; it does not add a GitHub network request.

## UI Integration

`SessionGitHubQuickAccessViewModel` is the lightweight row/card adapter. It can use:

- `GitHubPRObservationServiceProtocol` for shared PR/check observation
- `SessionGitHubQuickAccessCoordinatorProtocol` as a legacy PR-only shared source
- direct `GitHubCLIServiceProtocol` fallback when no shared source is available

`CollapsibleSessionRow` subscribes to session observation through the shared service. It starts with a small per-session stagger, records session activity, and stops polling on disappear. The GitHub row renders only when `currentBranchPR` is non-nil. Blockers use warning presentation; stale snapshots keep the last-known PR/check summary and disclose that refresh is unavailable. An inactive worktree session with a merged PR and no pending/failing CI replaces the terminal CI detail with a visible `Cleanup` action that routes through the existing worktree deletion confirmation.

`MonitoringCardView` uses the same quick-access view model for current branch PR access in the full session card.

`GitHubViewModel` subscribes to:

- the current branch target during panel setup
- the selected PR target while a PR detail view is active

The selected PR observation keeps PR metadata and CI checks fresh without reloading slower diff/file/comment payloads on every check update.

`MultiProviderSessionsListView` owns the sidebar refresh behavior. It gathers unique session targets from selected sessions, schedules a delayed initial refresh, and exposes a manual refresh action in the sessions header.

The global session panel derives GitHub attention from the same observation snapshots. Idle sessions with CI failure, requested changes, or merge conflicts are raised above ordinary idle work without displacing actively working sessions.

## Testing

Tests cover:

- target subscription deduplication
- deferred initial fetch until recent activity
- faster cadence for pending checks
- pending checks continuing after session idle and stopping at the one-hour cap
- slower cadence for settled checks
- automatic observation stopping for merged/closed PRs while manual refresh remains available
- terminal error pause/reactivation
- cancellation when the last subscriber unsubscribes
- manual one-shot cache population
- exact session-branch lookup
- repository-aware detected PR link selection
- embedded check-rollup decoding and fallback stale-data safety
- CI/review/merge blocker derivation
- safe merged-worktree cleanup eligibility
- global refresh concurrency limiting
- view model propagation of observed PR/check snapshots
- no-PR CLI output parsing

Relevant test files:

- `app/modules/AgentHubGitHub/Tests/AgentHubGitHubTests/GitHubPRObservationServiceTests.swift`
- `app/modules/AgentHubGitHub/Tests/AgentHubGitHubTests/SessionGitHubQuickAccessViewModelTests.swift`
- `app/modules/AgentHubGitHub/Tests/AgentHubGitHubTests/GitHubViewModelObservationTests.swift`
- `app/modules/AgentHubGitHub/Tests/AgentHubGitHubTests/GitHubCLIServiceTests.swift`

## Editing Guidelines

- Keep GitHub observation in `AgentHubGitHub`; UI modules should consume `GitHubPRObservationServiceProtocol`.
- Do not create per-view polling loops when a shared observation target can be reused.
- Preserve launch performance: new GitHub refresh work must be delayed, activity-driven, or manually triggered.
- Do not show no-PR states in compact session rows.
- Keep `gh` errors non-fatal for session rows; rows should fail quiet unless a PR is already known.
- Add or update unit tests when changing polling cadence, no-PR parsing, target deduplication, or UI visibility rules.
