# Patchset Protocol

Structured development in four phases with verification gates.

## Overview

| Patchset | Focus | Gate |
|----------|-------|------|
| PS1 | Models/Services | Types compile |
| PS2 | UI Wiring | Build succeeds |
| PS2.5 | Design Review | ui-polish SHIP YES |
| PS3 | Logic | Tests pass |
| PS4 | Polish | Full verification |

## PATCHSET 1: Models/Services Compile

### What to Do
- Create/modify data models
- Create/modify service actors
- Define error types
- Set up basic structure

### Verification
```bash
# Type check must pass
xcodebuild -project app/AgentHub.xcodeproj -scheme AgentHub build
```

### Contract Update
```markdown
- [x] PS1: Models compile
```

### Hand-off
→ Continue to PS2

## PATCHSET 2: UI Wired

### What to Do
- Create/modify SwiftUI views
- Wire views to state
- Add to navigation
- Basic layout complete

### Verification
```bash
# Full build must succeed
mcp__xcodebuildmcp__build_macos
```

### Contract Update
```markdown
- [x] PS2: UI wired
```

### Hand-off
→ If UI changes: ui-polish review (PS2.5)
→ Otherwise: Continue to PS3

## PATCHSET 2.5: Design Review

### What Happens
- ui-polish reviews UI against design bar
- Issues verdict: SHIP YES or SHIP NO
- If SHIP NO: Return to PS2 with feedback

### Contract Update
```markdown
- [x] PS2.5: ui-polish SHIP YES
```

### Hand-off
→ Continue to PS3

## PATCHSET 3: Logic Complete

### What to Do
- Implement business logic
- Add error handling
- Write tests
- Handle edge cases

### Verification
```bash
# Tests must pass
mcp__xcodebuildmcp__test_macos
```

### Contract Update
```markdown
- [x] PS3: Logic complete
```

### Hand-off
→ Continue to PS4

## PATCHSET 4: Polish

### What to Do
- Clean up code
- Remove debug statements
- Add documentation where needed
- Final review

### Verification
```bash
# Full build, no new warnings
mcp__xcodebuildmcp__build_macos
```

### Contract Update
```markdown
- [x] PS4: Polish done
```

### Hand-off
→ integrator final verification
→ Contract marked COMPLETE
→ DONE

## Rules

1. Complete each patchset before moving to next
2. Update contract checkboxes as you go
3. Don't skip design review for UI changes
4. integrator verifies at each gate
5. If blocked, return to previous patchset
