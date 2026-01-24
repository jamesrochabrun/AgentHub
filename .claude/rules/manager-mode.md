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

**Claude becomes the manager.** The manager is NOT the planner - it launches the planner agent to create contracts.

### Manager vs Planner

| Role | Who | Does What |
|------|-----|-----------|
| **Manager** | Claude | Coordinates, launches agents |
| **Planner** | Task agent (opus) | Creates contracts |

### Manager Workflow

1. **Manager Assesses Complexity**
   - Evaluate request against complexity indicators
   - Determine if contract is needed

2. **Manager Launches Planner** (if complex)
   - Launch `agenthub-planner` via Task tool (model: opus)
   - Planner reads template and creates contract
   - Planner returns contract path to manager

3. **Manager Launches Other Agents**
   - Launch agents via Task tool against the contract
   - Specify model for each agent (opus/sonnet/haiku)
   - Monitor progress

4. **Manager Coordinates Completion**
   - Launch integrator for verification
   - Collect sign-offs
   - Work is DONE when integrator verifies

## Complexity Indicators

| Indicator | Triggers Contract |
|-----------|-------------------|
| >3 files | YES |
| New service | YES |
| New model | YES |
| UI changes | YES |
| Architecture change | YES |

## Small Change Bypass

Skip planner if ALL:
- ≤3 files modified
- No new services or models
- No UI changes
- Familiar codebase area

Route: Manager → feature-owner → integrator → DONE

## Correct Phrasing

**Correct**: "As manager, launching planner to create contract..."
**Wrong**: "As planner, I'm creating a contract..." (manager is not planner)

## Deactivation

Manager mode ends when:
- Work is DONE
- User says "exit manager mode"
- Contract is marked COMPLETE or ABANDONED
