# AgentHub

macOS app for managing Claude Code sessions. Monitor sessions, create worktrees, preview diffs, run parallel terminals.

## Quick Reference

Build & Run:
- Use xcodebuildmcp: `build_run_macos` with scheme "AgentHub"
- Or: `xcodebuild -project app/AgentHub.xcodeproj -scheme AgentHub -configuration Debug build`

Project Structure:
- `app/AgentHub/` - Main app shell (SwiftUI lifecycle)
- `app/modules/AgentHubCore/` - Core framework (all logic)
  - `Services/` - Actor-based business logic
  - `Models/` - Data structures (Sendable, Codable)
  - `UI/` - SwiftUI views
  - `ViewModels/` - Observable UI state
  - `Configuration/` - Provider, Defaults, Environment

## Agent System v2.0

### Quick Reference

| To Learn About | See |
|----------------|-----|
| Manager mode activation | `.claude/rules/manager-mode.md` |
| Design bar / Jobs Critique | `.claude/rules/design-bar.md` |
| Context7 usage | `.claude/rules/context7-mandatory.md` |
| Contract template | `.claude/contracts/CONTRACT_TEMPLATE.md` |
| Service patterns | `.claude/rules/service-patterns.md` |
| Concurrency patterns | `.claude/rules/concurrency-patterns.md` |

### How to Use Agents

**By default**, Claude works directly on tasks (fast, no overhead).

**To activate the agent system**, say any of:
- "act as a manager"
- "manager mode"
- "orchestrate this"
- "use agents"

### Planner Role (CRITICAL)

When manager mode activates, **Claude becomes the planner**. The planner is NOT a separate agent - it's Claude in orchestration mode.

**As planner, Claude must:**
1. Speak as planner: "As planner, I'm creating a contract..."
2. Create contracts from `.claude/contracts/CONTRACT_TEMPLATE.md`
3. Launch other agents via Task tool (with model specified)
4. Stay external to the contract - planner doesn't appear in Agent Assignments

**Correct**: "As planner, I'm assessing complexity and creating a contract."
**Wrong**: "I'm activating manager mode..." or "Let me create a contract..."

See `.claude/rules/manager-mode.md` and `.claude/agents/agenthub-planner.md` for full details.

### THE CONTRACT SYSTEM (Core Concept)
For complex work (>3 files, new services, UI changes), a CONTRACT is created BEFORE implementation.
- Contracts live in `.claude/contracts/<feature>.md`
- Template at `.claude/contracts/CONTRACT_TEMPLATE.md`
- feature-owner CANNOT start without active contract
- integrator verifies contract completion before DONE

### Planner + Six Agents

**Planner** = Claude in orchestration mode (creates contracts, launches agents)

| Agent | Model | Role | Access |
|-------|-------|------|--------|
| **agenthub-explorer** | sonnet | Context finder | Read-only |
| **feature-owner** | opus | Implementation | Full edit |
| **ui-polish** | sonnet | Design bar + refinement | Full edit |
| **xcode-pilot** | haiku | Simulator validation | Simulator |
| **integrator** | sonnet | Final verification | Read-only |
| **swift-debugger** | opus | Bug investigation | Read + Execute |

### Request Routing

**Small Change** (≤3 files, no new services, familiar area):
```
Planner → feature-owner → integrator → DONE
```

**Complex Change**:
```
Planner: Create contract from template
Planner: Launch agenthub-explorer (if unfamiliar area)
Planner: Launch feature-owner (PS1-PS4)
Planner: Launch ui-polish (if UI changes) → SHIP YES/NO
Planner: Launch xcode-pilot (if high-risk)
Planner: Launch integrator → DONE
```

### Patchset Protocol

| Patchset | Gate | Verification |
|----------|------|--------------|
| 1 | Models compile | Type check passes |
| 2 | UI wired | Build succeeds |
| 2.5 | Design bar | ui-polish SHIP YES |
| 3 | Logic complete | Tests pass |
| 4 | Polish | Full build + lint |

### Interface Locks (Contracts)

**Contracts are mandatory for complex work.** agenthub-planner creates `.claude/contracts/<feature>.md` BEFORE any implementation begins.

Contract Rules:
1. NO implementation without an active contract (for complex work)
2. feature-owner MUST reference contract in each patchset
3. Contract updated as work progresses
4. integrator checks contract completion before DONE

See `.claude/contracts/CONTRACT_TEMPLATE.md` for the full template.

## Architecture Patterns

### Adding a Service
```swift
// Services/MyService.swift
public actor MyService {
  public func doWork() async throws -> Result { }
}

// Configuration/AgentHubProvider.swift
public private(set) lazy var myService: MyService = { MyService() }()
```

### Adding a View
```swift
// UI/MyView.swift
struct MyView: View {
  @Environment(AgentHubEnvironment.self) var env
  var body: some View { /* ... */ }
}
```

### Error Handling
```swift
public enum MyServiceError: LocalizedError, Sendable {
  case operationFailed(String)
  public var errorDescription: String? { /* ... */ }
}
```

## Rules (Enforced)

1. **Concurrency**: Use async/await and actors. No Combine.
2. **Thread Safety**: All models must be Sendable.
3. **Logging**: Use AppLogger subsystems (git, session, etc.)
4. **Design Bar**: UI changes require ui-polish SHIP YES.
5. **Context7**: Check docs before using unfamiliar APIs.

## Key Files

- `AgentHubProvider.swift` - Dependency injection container
- `CLISessionMonitorService.swift` - Session watching
- `GitWorktreeService.swift` - Worktree operations
- `GitDiffService.swift` - Diff generation
- `AppLogger.swift` - Logging subsystems

## Agent System Files

- `.claude/agents/` - Agent definitions
- `.claude/contracts/` - Active and completed contracts
- `.claude/rules/` - Enforced rules
- `.claude/skills/` - Audit and review skills
- `.claude/docs/AGENT_SYSTEM.md` - Full system documentation
