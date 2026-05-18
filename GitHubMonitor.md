# GitHub PR/CI Monitor

AgentHub observes GitHub pull request state and CI checks through a shared service in the `AgentHubGitHub` module. The goal is to let multiple UI surfaces show current PR/check state without each surface starting its own `gh` polling loop.

## User Behavior

- GitHub monitoring is optional and only works when the GitHub CLI (`gh`) is installed, authenticated, and the session project is a GitHub repository.
- Session rows show GitHub status only when the current session branch has a pull request. Branches with no PR stay visually quiet.
- When a PR exists, the side-panel session row shows a compact bottom line with PR state and CI summary, for example `Draft PR #20 - CI passing 1/1`.
- Monitoring cards can expose the current branch PR as quick access.
- The GitHub panel observes the current branch PR and the selected PR detail/check state.
- The side panel refresh button forces a refresh for the visible session branch targets.

## Architecture

The shared service is `GitHubPRObservationService`, an actor that implements `GitHubPRObservationServiceProtocol`.

Core types:

- `GitHubPRObservationTarget`
  - `.currentBranch(projectPath:branchName:)`
  - `.pullRequest(projectPath:number:)`
- `GitHubPRObservationSnapshot`
  - target
  - optional pull request
  - check runs
  - derived `GitHubCISummary`
  - observation state
  - last refresh date
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

For current-branch targets, the service calls:

1. `getCurrentBranchPR(at:)`
2. `getChecks(prNumber:at:)` only if a PR exists

For explicit PR targets, the service fetches PR metadata and checks concurrently.

`GitHubCLIService.getCurrentBranchPR(at:)` treats GitHub CLI's "no pull requests found for branch ..." response as a valid no-PR result, not as a UI error.

## Polling And Performance

Default observation configuration:

- Pending checks or no discovered PR: refresh every 30 seconds while active
- Settled PR checks: refresh every 120 seconds while active
- Idle timeout: stop automatic polling after 5 minutes without session activity
- Transient error backoff: 60 seconds, 120 seconds, then 300 seconds

Performance rules:

- The service only polls targets with active subscribers.
- Unsubscribing the last subscriber cancels the scheduled polling task for that target.
- Multiple subscribers for the same target share one snapshot and one scheduled refresh.
- If a refresh is already running, additional activity is coalesced and evaluated after the current refresh finishes.
- Terminal setup errors (`gh` missing, unauthenticated, not a git repository, no remote) pause automatic polling until new activity or a manual refresh reactivates the target.
- Session row subscriptions can opt out of immediate fetches with `refreshOnSubscribe: false`; activity timestamps decide whether observation should start.
- Initial sidebar refresh is delayed until after launch and limited to a small batch so GitHub state does not block app startup.
- Manual refresh walks the current branch targets sequentially with a short delay between targets to avoid a burst of `gh` processes.

## UI Integration

`SessionGitHubQuickAccessViewModel` is the lightweight row/card adapter. It can use:

- `GitHubPRObservationServiceProtocol` for shared PR/check observation
- `SessionGitHubQuickAccessCoordinatorProtocol` as a legacy PR-only shared source
- direct `GitHubCLIServiceProtocol` fallback when no shared source is available

`CollapsibleSessionRow` subscribes to current-branch observation through the shared service. It starts with a small per-session stagger, records session activity, and stops polling on disappear. The GitHub row renders only when `currentBranchPR` is non-nil.

`MonitoringCardView` uses the same quick-access view model for current branch PR access in the full session card.

`GitHubViewModel` subscribes to:

- the current branch target during panel setup
- the selected PR target while a PR detail view is active

The selected PR observation keeps PR metadata and CI checks fresh without reloading slower diff/file/comment payloads on every check update.

`MultiProviderSessionsListView` owns the sidebar refresh behavior. It gathers unique current-branch targets from selected sessions, schedules a delayed initial refresh, and exposes a manual refresh action in the sessions header.

## Testing

Tests cover:

- target subscription deduplication
- deferred initial fetch until recent activity
- faster cadence for pending checks
- slower cadence for settled checks
- terminal error pause/reactivation
- cancellation when the last subscriber unsubscribes
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
