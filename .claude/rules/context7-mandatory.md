# Context7 Attestation Required

Before writing code that uses frameworks or libraries, check the documentation first.

## When Required

- Using unfamiliar APIs
- Framework-specific patterns
- Third-party library integration
- Apple framework usage (SwiftUI, Combine alternatives, etc.)

## How to Use Context7

### Step 1: Resolve Library ID
```
mcp__context7__resolve-library-id
```
Parameters:
- `libraryName`: The library to look up
- `query`: What you're trying to accomplish

### Step 2: Query Documentation
```
mcp__context7__query-docs
```
Parameters:
- `libraryId`: From step 1
- `query`: Specific question about usage

## Contract Attestation

In the contract, attest:
```markdown
## Context7 Attestation
- [x] Checked docs for: SwiftUI, Sparkle
- Libraries verified: /apple/swiftui, /sparkle-project/sparkle
```

## Common Libraries for AgentHub

| Library | Context7 ID |
|---------|-------------|
| SwiftUI | /apple/swiftui |
| Swift Concurrency | /apple/swift |
| Sparkle | /sparkle-project/sparkle |

## Rules

1. Check Context7 BEFORE implementing framework code
2. Document which libraries were checked in contract
3. If Context7 doesn't have docs, note that too
4. Don't guess at APIs - verify first

## Exceptions

No Context7 needed for:
- Pure business logic
- Simple Swift standard library
- Code following existing patterns in codebase
