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
   - Planner assesses complexity
   - Determines if contract is needed

2. **Contract Creation** (if complex)
   - Planner creates contract from `.claude/contracts/CONTRACT_TEMPLATE.md`
   - Contract placed in `.claude/contracts/<feature-slug>.md`
   - Acceptance criteria defined (max 3)
   - Agents assigned to contract (planner stays external)

3. **Orchestrated Execution**
   - Planner launches agents against the contract
   - Work follows patchset protocol (PS1-PS4)
   - Agents hand off at defined gates
   - Progress tracked in contract checkboxes

4. **Verification**
   - integrator verifies at each patchset
   - Sign-offs collected in contract
   - Contract marked COMPLETE

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
