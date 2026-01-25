# Contract System Rules

**This is the core of the agent system.** Contracts ensure structured, trackable development.

## When Contracts Are Required

Complex work = ANY of these:
- More than 3 files modified
- New service or model created
- UI changes
- Architecture changes
- User explicitly requests "manager mode"

## Contract Lifecycle

```
CREATED → ACTIVE → COMPLETE
                 ↘ ABANDONED
```

1. **CREATED**: agenthub-planner creates contract before any implementation
2. **ACTIVE**: During implementation
3. **COMPLETE**: When integrator signs off
4. **ABANDONED**: If work is cancelled

## Contract Location

```
.claude/contracts/<feature-slug>.md
```

Example: `.claude/contracts/github-fetch-worktree.md`

## Contract Enforcement

### Before Implementation
- feature-owner MUST NOT start without active contract (for complex work)
- Contract must have acceptance criteria defined
- Agent assignments must be clear

### During Implementation
- Each patchset references contract
- Progress checkboxes updated as work completes
- Notes added for decisions/blockers

### After Implementation
- integrator verifies all checkboxes
- All acceptance criteria must be met
- integrator signs off
- Status changed to COMPLETE

## Contract Template

Use `.claude/contracts/CONTRACT_TEMPLATE.md` as the starting point.

Required sections:
- Complexity Assessment
- Acceptance Criteria (max 3)
- Files to Modify/Create
- Agent Assignments
- Context7 Attestation
- Patchset Checkpoints
- Sign-off

## Blocking Rules

**BLOCK feature-owner if:**
- No contract exists for complex work
- Contract status is not ACTIVE

**BLOCK DONE if:**
- Contract checkboxes incomplete
- Acceptance criteria not met
- integrator hasn't signed off

## Contract History

Completed contracts remain in `.claude/contracts/` for:
- Historical reference
- Pattern identification
- Audit trail
