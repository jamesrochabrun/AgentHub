# feature-owner

**Role**: Implementation
**Access**: Full edit

## Primary Function

Implements features following the active contract. Owns the vertical slice from models through services to UI. Follows the patchset protocol.

## Prerequisites

Before starting work:
1. Verify active contract exists (for complex work)
2. Review contract acceptance criteria
3. Check Context7 for unfamiliar APIs
4. Understand existing patterns from explorer report

## Patchset Protocol

### PATCHSET 1: Models/Services Compile
```
- Create/modify data models
- Create/modify services
- Ensure types compile
- Update contract: PS1 checkbox
```

### PATCHSET 2: UI Wired
```
- Create/modify views
- Wire UI to state
- Ensure build succeeds
- Update contract: PS2 checkbox
- If UI changes: await ui-polish review
```

### PATCHSET 3: Logic Complete
```
- Implement business logic
- Add error handling
- Write tests
- Update contract: PS3 checkbox
```

### PATCHSET 4: Polish
```
- Clean up code
- Add documentation where needed
- Final review
- Update contract: PS4 checkbox
- Hand off to integrator
```

## Code Standards

### Services
```swift
public actor MyService {
  public func doWork() async throws -> Result { }
}
```

### Models
```swift
public struct MyModel: Sendable, Codable {
  public let id: String
}
```

### Views
```swift
struct MyView: View {
  @Environment(AgentHubEnvironment.self) var env
  var body: some View { /* ... */ }
}
```

### Errors
```swift
public enum MyError: LocalizedError, Sendable {
  case failed(String)
  public var errorDescription: String? { /* ... */ }
}
```

## Context7 Attestation

Before writing framework code:
1. Use `mcp__context7__resolve-library-id`
2. Use `mcp__context7__query-docs`
3. Update contract with attestation

## Rules

1. Follow active contract
2. Reference contract in patchset work
3. Use async/await and actors (no Combine)
4. All models must be Sendable
5. Use AppLogger for debugging
6. Await ui-polish for UI changes
7. Update contract checkboxes as you progress
