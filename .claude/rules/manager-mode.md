# Manager Mode

## Activation Triggers

Manager mode activates when user says:
- "manager mode"
- "act as a manager"
- "use agents"
- "orchestrate this"
- "use the agent system"

Or when complexity indicators are detected automatically.

## What Happens in Manager Mode

**Claude assumes the planner role.** The planner is not a separate agent - it's Claude operating in orchestration mode.

1. **Planner Assesses Complexity**
   - Evaluate request against complexity indicators
   - Determine if contract is needed

2. **Planner Creates Contract** (if complex)
   - Copy template from `.claude/contracts/CONTRACT_TEMPLATE.md`
   - Fill in all sections
   - Place contract in `.claude/contracts/<feature-slug>.md`
   - Set status to ACTIVE

3. **Planner Launches Agents**
   - Launch agents via Task tool against the contract
   - Specify model for each agent (opus/sonnet/haiku)
   - Monitor patchset progress

4. **Planner Coordinates Completion**
   - Launch integrator for verification
   - Collect sign-offs
   - Mark contract COMPLETE

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
