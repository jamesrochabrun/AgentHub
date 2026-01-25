# Contract: <Feature Name>

**ID**: <PREFIX>-<NUMBER>
**Created**: <YYYY-MM-DD>
**Status**: DRAFT | ACTIVE | BLOCKED | COMPLETE | ABANDONED
**Owner**: <assigned feature-owner>

---

## Problem Statement

_What problem are we solving? Why does this matter to users?_

<Clear, concise description of the problem and user impact>

---

## Acceptance Criteria

| # | Criterion | Verified |
|---|-----------|----------|
| AC1 | <Specific, testable outcome> | [ ] |
| AC2 | <Specific, testable outcome> | [ ] |
| AC3 | <Specific, testable outcome> | [ ] |

_Max 3 criteria. Each must be binary (done/not done)._

---

## Scope

### In Scope
- <What this contract WILL deliver>
- <Be specific>

### Out of Scope
- <What this contract will NOT touch>
- <Prevents scope creep>

---

## Technical Design

### Files to Modify

| File | Changes |
|------|---------|
| `<path>` | <description> |

### Files to Create

| File | Purpose |
|------|---------|
| `<path>` | <description> |

### Key Interfaces

```swift
// Define key types, protocols, or function signatures here
// This locks the interface before implementation begins
```

### Data Flow

_Optional: Describe how data flows through the system for this feature_

---

## Patchset Protocol

| PS | Gate | Deliverables | Status |
|----|------|--------------|--------|
| 1 | Models compile | Types, service stubs, error enums | [ ] |
| 2 | UI wired | Views created, navigation working | [ ] |
| 2.5 | Design bar | ui-polish SHIP YES | [ ] |
| 3 | Logic complete | Full implementation, tests pass | [ ] |
| 4 | Polish | Clean build, no warnings | [ ] |

### PS1 Checklist
- [ ] All new types are Sendable
- [ ] Services are actors
- [ ] Error types defined
- [ ] Build succeeds

### PS2 Checklist
- [ ] Views created and navigable
- [ ] State wired to views
- [ ] Build succeeds

### PS2.5 Checklist (UI only)
- [ ] Ruthless simplicity
- [ ] One clear primary action
- [ ] Strong visual hierarchy
- [ ] No clutter
- [ ] Native macOS feel

### PS3 Checklist
- [ ] Business logic implemented
- [ ] Error handling complete
- [ ] Edge cases covered

### PS4 Checklist
- [ ] No compiler warnings
- [ ] No debug statements
- [ ] Code is clean

---

## Context7 Attestation

_MANDATORY: Agents must check Context7 docs before using ALL APIs (training data is outdated). Claude is especially weak on Swift - ALWAYS verify._

### Required Libraries (planner fills)

| Library | Context7 ID | Why Needed |
|---------|-------------|------------|
| SwiftUI | /apple/swiftui | <reason> |
| <other> | <id> | <reason> |

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
┌───────────────────┐
│ agenthub-explorer │ ─── Gathers context (if unfamiliar area)
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│   feature-owner   │ ─── PS1 → PS2 → PS3 → PS4
└────────┬──────────┘
         │
         ▼ (after PS2, if UI changes)
┌───────────────────┐
│     ui-polish     │ ─── PS2.5: SHIP YES / SHIP NO
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│    integrator     │ ─── Final verification
└───────────────────┘
```

### Agent Assignments

| Agent | Responsibility | Status |
|-------|---------------|--------|
| agenthub-explorer | Context gathering | [ ] Done / [ ] Skipped |
| feature-owner | Implementation PS1-4 | [ ] Done |
| ui-polish | Design review PS2.5 | [ ] Done / [ ] N/A |
| integrator | Final gate | [ ] Done |

---

## Blockers & Decisions

| Date | Issue | Decision | Decided By |
|------|-------|----------|------------|
| | | | |

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
