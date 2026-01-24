# AgentHub Agent System v2.0

Complete documentation for the multi-agent development system.

## Overview

The AgentHub agent system enables structured, trackable development through specialized agents, contracts, and verification gates. It's designed for complex features that benefit from orchestration.

## Core Concept: Contracts

**Contracts are the heart of the system.** For complex work, a contract is created BEFORE implementation begins. The contract:

- Defines acceptance criteria
- Lists files to modify
- Assigns agents
- Tracks progress through patchsets
- Requires sign-off before completion

## Activation

The system activates when:
- User says "manager mode", "use agents", or "orchestrate this"
- Complexity indicators are detected (>3 files, new services, UI changes)

## The Seven Agents

### 1. agenthub-planner (Orchestrator)
**Access**: Read-only

The entry point. Routes requests, creates contracts, assigns agents. Never writes code directly.

**Key responsibilities:**
- Assess request complexity
- Create contracts for complex work
- Route to appropriate agents
- Monitor progress

### 2. agenthub-explorer (Context Finder)
**Access**: Read-only

Gathers context before implementation. Maps dependencies, finds patterns, reports findings.

**Key responsibilities:**
- Explore unfamiliar codebase areas
- Map dependencies
- Identify patterns to follow
- Suggest Context7 lookups

### 3. feature-owner (Implementation)
**Access**: Full edit

The builder. Implements features following contracts and patchset protocol.

**Key responsibilities:**
- Follow active contract
- Implement in patchsets (PS1-4)
- Attest Context7 usage
- Update contract progress

### 4. ui-polish (Design Bar + Refinement)
**Access**: Full edit

Enforces design quality. Reviews UI, issues SHIP YES/NO verdicts, handles polish.

**Key responsibilities:**
- Review UI against design bar
- Issue clear verdicts
- Handle polish after approval
- Ensure accessibility

### 5. xcode-pilot (Simulator Validation)
**Access**: Simulator tools

Validates changes by building and testing in simulator.

**Key responsibilities:**
- Build and run app
- Navigate to affected areas
- Verify behavior
- Report issues

### 6. integrator (Final Gate)
**Access**: Read-only

Final verification before DONE. Checks contracts, builds, tests.

**Key responsibilities:**
- Verify at each patchset
- Check contract completion
- Run builds and tests
- Sign off on contracts

### 7. swift-debugger (Bug Investigation)
**Access**: Read + Execute

Investigates bugs, performs root cause analysis, reports findings.

**Key responsibilities:**
- Reproduce issues
- Analyze causes
- Report findings
- Suggest fixes (doesn't implement)

## Request Routing

### Simple Request Flow
```
Request → feature-owner → integrator → DONE
```
Used when: ≤3 files, no new services, no UI changes, familiar area

### Complex Request Flow
```
Request → agenthub-planner (creates contract)
        → agenthub-explorer (if unfamiliar)
        → feature-owner (PS1-4)
        → ui-polish (if UI) → SHIP YES/NO
        → xcode-pilot (if high-risk)
        → integrator → DONE
```

## Patchset Protocol

| Patchset | Focus | Verification |
|----------|-------|--------------|
| PS1 | Models/Services | Types compile |
| PS2 | UI Wiring | Build succeeds |
| PS2.5 | Design Review | ui-polish SHIP YES |
| PS3 | Logic | Tests pass |
| PS4 | Polish | Full verification |

Each patchset updates the contract checkbox before proceeding.

## Contract Structure

Contracts live in `.claude/contracts/<feature-slug>.md`.

```markdown
# Contract: <Feature Name>
Status: ACTIVE

## Complexity Assessment
- Files touched: X
- New services: YES/NO
- UI changes: YES/NO

## Acceptance Criteria (max 3)
1. [ ] Criteria one
2. [ ] Criteria two
3. [ ] Criteria three

## Files to Modify/Create
- path/to/file.swift - purpose

## Agent Assignments
- feature-owner: Implementation
- ui-polish: Design review
- integrator: Final gate

## Patchset Checkpoints
- [ ] PS1: Models compile
- [ ] PS2: UI wired
- [ ] PS3: Logic complete
- [ ] PS4: Polish done

## Sign-off
- [ ] integrator: VERIFIED
```

## Contract Lifecycle

1. **CREATED** - agenthub-planner creates before implementation
2. **ACTIVE** - During implementation
3. **COMPLETE** - integrator signs off
4. **ABANDONED** - Work cancelled

## Design Bar (ui-polish)

Five checks for every UI change:
1. Ruthless simplicity
2. One clear primary action
3. Strong visual hierarchy
4. No clutter
5. Native macOS feel

**Verdict: SHIP YES or SHIP NO** - No middle ground.

## Context7 Attestation

Before using framework APIs:
1. `mcp__context7__resolve-library-id`
2. `mcp__context7__query-docs`
3. Document in contract

## Skills Available

| Skill | Purpose |
|-------|---------|
| swiftui-a11y-audit | Accessibility review |
| swiftui-layout-sanity | Layout debugging |
| swift-concurrency | Concurrency patterns |
| performance-smoke | Performance checks |
| releasing-macos-apps | Release workflow |

## Rules Reference

| Rule | File |
|------|------|
| Manager Mode | `.claude/rules/manager-mode.md` |
| Contract System | `.claude/rules/contract-system.md` |
| Design Bar | `.claude/rules/design-bar.md` |
| Context7 | `.claude/rules/context7-mandatory.md` |
| Service Patterns | `.claude/rules/service-patterns.md` |
| Concurrency | `.claude/rules/concurrency-patterns.md` |
| Patchset Protocol | `.claude/rules/patchset-protocol.md` |

## File Structure

```
.claude/
├── agents/           # Agent definitions
├── contracts/        # Active and completed contracts
├── rules/            # Enforced rules
├── skills/           # Audit and review skills
└── docs/             # This documentation
```

## Quick Reference

**Start manager mode:**
> "manager mode" or "use agents"

**Create contract:**
> Automatic for complex work, or request explicitly

**Check progress:**
> Review contract in `.claude/contracts/`

**Exit manager mode:**
> "exit manager mode" or complete the work
