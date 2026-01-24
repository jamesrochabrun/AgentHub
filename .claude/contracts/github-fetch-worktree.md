# Contract: GitHub Fetch Worktree & Repository Management

**ID**: GFW-001
**Created**: 2026-01-24
**Status**: ACTIVE
**Owner**: feature-owner

---

## Problem Statement

Users creating worktrees can only see local branches, missing remote branches that may have been created by teammates. Additionally, there's no way to add repositories from GitHub directly, and users can't configure where AgentHub stores its cloned repositories.

**User impact:**
1. Must manually fetch before seeing new remote branches
2. Must manually clone repos before adding to AgentHub
3. Repositories scattered across filesystem with no organization

---

## Acceptance Criteria

| # | Criterion | Verified |
|---|-----------|----------|
| AC1 | Worktree creation sheet fetches from GitHub and shows remote branches | [ ] |
| AC2 | Users can add repositories from GitHub via URL | [ ] |
| AC3 | Users can configure a dedicated AgentHub storage directory that auto-organizes repos | [ ] |

---

## Scope

### In Scope
- Add `.fetching` state to `WorktreeCreationProgress` for fetch operation
- Modify `CreateWorktreeSheet` to use `fetchAndGetRemoteBranches()` instead of `getLocalBranches()`
- Create service for cloning repositories from GitHub URLs
- Create UI for adding repositories from GitHub
- Create settings/configuration for repository storage location
- Auto-organization of cloned repos within AgentHub directory

### Out of Scope
- GitHub authentication (use public repos or existing git credentials)
- GitHub API integration for browsing/searching repos
- Syncing existing repos into the AgentHub directory
- Private repo access beyond existing SSH/credential setup

---

## Technical Design

### Files to Modify

| File | Changes |
|------|---------|
| `Models/WorktreeCreationProgress.swift` | Add `.fetching` case with appropriate progress value, message, and icon |
| `UI/CreateWorktreeSheet.swift` | Change `loadBranches()` to use `fetchAndGetRemoteBranches()`, update loading UI to show fetch progress |
| `Configuration/AgentHubDefaults.swift` | Add keys for storage directory path and repository configurations |
| `Configuration/AgentHubProvider.swift` | Add `repositoryStorageService` lazy property |
| `UI/CLIRepositoryPickerView.swift` | Add option to add from GitHub URL (alongside existing local picker) |

### Files to Create

| File | Purpose |
|------|---------|
| `Services/RepositoryStorageService.swift` | Actor service for cloning repos and managing storage directory |
| `Models/RepositoryConfiguration.swift` | Model for stored repository config (path, origin URL, last fetched) |
| `UI/AddRepositorySheet.swift` | Sheet with options: local folder picker OR GitHub URL input |
| `UI/StorageSettingsView.swift` | Settings view for configuring AgentHub storage directory |

### Key Interfaces

```swift
// WorktreeCreationProgress.swift - Add fetching case
public enum WorktreeCreationProgress: Equatable, Sendable {
  case idle
  case fetching  // NEW: Added for GitHub fetch
  case preparing(message: String)
  case updatingFiles(current: Int, total: Int)
  case completed(path: String)
  case failed(error: String)
}

// RepositoryConfiguration.swift
public struct RepositoryConfiguration: Codable, Sendable, Identifiable {
  public var id: String { path }
  public let path: String
  public let originURL: String?
  public let addedDate: Date
  public var lastFetchedDate: Date?
}

// RepositoryStorageService.swift
public actor RepositoryStorageService {
  /// Default storage directory (~/AgentHub or configurable)
  public func getStorageDirectory() async -> String

  /// Set custom storage directory
  public func setStorageDirectory(_ path: String) async

  /// Clone repository from URL into storage directory
  public func cloneRepository(from url: String, name: String?) async throws -> String

  /// List all managed repositories
  public func getManagedRepositories() async -> [RepositoryConfiguration]

  /// Add existing local repository to managed list
  public func addLocalRepository(at path: String) async throws
}
```

### Data Flow

```
[User clicks "Add Repository"]
         │
         ▼
   ┌─────────────────┐
   │ AddRepositorySheet │ ─── Choose: Local folder OR GitHub URL
   └────────┬────────┘
            │
    ┌───────┴───────┐
    ▼               ▼
[Local Picker]  [GitHub URL]
    │               │
    ▼               ▼
[Add path to   [Clone to AgentHub/
 managed list]  storage directory]
    │               │
    └───────┬───────┘
            ▼
   [Repository appears in sidebar]


[User clicks "Create Worktree"]
         │
         ▼
   ┌─────────────────┐
   │ CreateWorktreeSheet │
   └────────┬────────┘
            │
            ▼
   [Show .fetching state]
            │
            ▼
   [Call fetchAndGetRemoteBranches()]
            │
            ▼
   [Show remote branches in picker]
            │
            ▼
   [Create worktree as sibling to main repo]
```

---

## Patchset Protocol

| PS | Gate | Deliverables | Status |
|----|------|--------------|--------|
| 1 | Models compile | `RepositoryConfiguration`, `WorktreeCreationProgress.fetching`, `RepositoryStorageService` stub | [ ] |
| 2 | UI wired | `AddRepositorySheet`, `StorageSettingsView`, updated `CreateWorktreeSheet` | [ ] |
| 2.5 | Design bar | ui-polish SHIP YES | [ ] |
| 3 | Logic complete | Full clone logic, storage management, fetch integration | [ ] |
| 4 | Polish | Clean build, no warnings | [ ] |

### PS1 Checklist
- [ ] `RepositoryConfiguration` is Sendable and Codable
- [ ] `RepositoryStorageService` is an actor
- [ ] `WorktreeCreationProgress.fetching` case added with properties
- [ ] Error types defined in service
- [ ] `AgentHubDefaults` keys added
- [ ] Build succeeds

### PS2 Checklist
- [ ] `AddRepositorySheet` shows local picker and GitHub URL options
- [ ] `StorageSettingsView` allows picking storage directory
- [ ] `CreateWorktreeSheet` shows fetching progress
- [ ] Views wired to state
- [ ] Build succeeds

### PS2.5 Checklist (UI only)
- [ ] Ruthless simplicity - AddRepositorySheet has clear two options
- [ ] One clear primary action - obvious "Add" or "Clone" button
- [ ] Strong visual hierarchy - URL input prominent when selected
- [ ] No clutter - minimal fields, clean layout
- [ ] Native macOS feel - standard sheet patterns, system controls

### PS3 Checklist
- [ ] `cloneRepository()` runs `git clone` properly
- [ ] Storage directory created if missing
- [ ] Repository configs persisted to UserDefaults
- [ ] `fetchAndGetRemoteBranches()` integrated in CreateWorktreeSheet
- [ ] Error handling for invalid URLs, clone failures

### PS4 Checklist
- [ ] No compiler warnings
- [ ] No debug statements
- [ ] Code is clean

---

## Context7 Attestation

_MANDATORY: Agents must check Context7 docs before using ALL APIs (training data is outdated). Claude is especially weak on Swift - ALWAYS verify._

### Required Libraries (planner identified)

| Library | Context7 ID | Why Needed |
|---------|-------------|------------|
| SwiftUI | /apple/swiftui | Sheet presentation, TextField for URL input |
| Foundation | /apple/swift | FileManager for directory creation, Process for git clone |

### Agent Reports (each agent fills their section)

**feature-owner**:
| Library | Query | Result |
|---------|-------|--------|
| _fill when implementing_ | | |

**ui-polish**:
| Library | Query | Result |
|---------|-------|--------|
| _fill if API used_ | | |

**swift-debugger** (if invoked):
| Library | Query | Result |
|---------|-------|--------|
| _fill if investigating API_ | | |

---

## Agent Workflow

_Note: The **planner** creates this contract and orchestrates execution. It is not listed below because it operates outside the contract - agents below execute against the contract._

```








           (after PS2, if UI changes)







```

### Agent Assignments

| Agent | Responsibility | Status |
|-------|---------------|--------|
| agenthub-explorer | Context gathering | [x] Done (planner gathered context) |
| feature-owner | Implementation PS1-4 | [ ] Done |
| ui-polish | Design review PS2.5 | [ ] Done |
| integrator | Final gate | [ ] Done |

---

## Blockers & Decisions

| Date | Issue | Decision | Decided By |
|------|-------|----------|------------|
| 2026-01-24 | Default storage location | Use `~/AgentHub` as default, configurable via settings | planner |
| 2026-01-24 | GitHub auth | Out of scope - rely on existing git credentials (SSH keys, credential helper) | planner |

---

## Sign-off

| Role | Signature | Date |
|------|-----------|------|
| feature-owner | [ ] PS1-4 complete | |
| ui-polish | [ ] SHIP YES | |
| integrator | [ ] VERIFIED | |

**Contract Completion**: _pending_

---

## Post-Completion Notes

_After COMPLETE: What did we learn? What would we do differently?_
