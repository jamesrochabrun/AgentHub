# Context7 Attestation Required

**MANDATORY: Check Context7 for ALL APIs before using them.** Training data is outdated - always verify current documentation.

## ESPECIALLY for Swift

**Claude is NOT well-trained on Swift.** Swift evolves rapidly and Claude's training data lags behind. Context7 is CRITICAL for:
- SwiftUI (constantly changing APIs)
- Swift Concurrency (actors, async/await patterns)
- Observation framework (@Observable vs @ObservableObject)
- Modern Swift syntax and patterns

**NEVER assume Swift knowledge is correct. ALWAYS verify with Context7.**

## When Required

**ALWAYS** - for any framework or library usage:
- SwiftUI views, modifiers, patterns
- Foundation APIs
- Apple frameworks
- Third-party libraries
- Concurrency patterns

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

1. **ALWAYS** check Context7 before using ANY API
2. Document which libraries were checked in contract
3. If Context7 doesn't have docs, note that too
4. Don't guess at APIs - verify first
5. Training data is outdated - Context7 has current docs

## NO Exceptions

Context7 is required for ALL API usage. Do not skip this step.
