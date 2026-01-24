# Manager Mode

## Activation Triggers

Manager mode activates when user says:
- "manager mode"
- "use agents"
- "orchestrate this"
- "use the agent system"

Or when complexity indicators are detected automatically.

## What Happens in Manager Mode

1. **Request Analysis**
   - agenthub-planner assesses complexity
   - Determines if contract is needed

2. **Contract Creation** (if complex)
   - Contract created in `.claude/contracts/`
   - Acceptance criteria defined
   - Agents assigned

3. **Orchestrated Execution**
   - Work follows patchset protocol
   - Agents hand off at defined gates
   - Progress tracked in contract

4. **Verification**
   - integrator verifies at each patchset
   - Final gate before DONE

## Complexity Indicators

| Indicator | Triggers Contract |
|-----------|-------------------|
| >3 files | YES |
| New service | YES |
| New model | YES |
| UI changes | YES |
| Architecture change | YES |

## Small Change Bypass

Skip full orchestration if ALL:
- ≤3 files modified
- No new services or models
- No UI changes
- Familiar codebase area

Route: feature-owner → integrator → DONE

## Deactivation

Manager mode ends when:
- Work is DONE
- User says "exit manager mode"
- Contract is marked COMPLETE or ABANDONED
