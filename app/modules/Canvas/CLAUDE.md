# Canvas — Project Guide

## Build & Test

```bash
swift build        # Build the library
swift test         # Run all tests (Swift Testing framework)
swift test --filter ElementInspectStateTests   # Run a specific test suite
```

- **Platform**: macOS 14+
- **Swift tools version**: 6.0
- **Swift language mode**: 5

## Architecture

Canvas is a macOS Swift package for web element inspection in WKWebView.

```
Sources/Canvas/
  ElementInspectState.swift           — @Observable state machine (InspectMode, lifecycle)
  ElementInspectorData.swift          — Immutable Sendable struct for captured DOM data
  ElementInspectorBridge.swift        — JS injection, WKScriptMessageHandler, parsing
  InspectableWebView.swift            — NSViewRepresentable wrapping WKWebView
  WebInspectInputView.swift           — Floating text-input overlay (input mode)
  WebInspectContextView.swift         — Read-only element summary (context mode)
  WebInspectorOverlay.swift           — ViewModifier combining banner + overlays
  ElementInspectorPromptBuilder.swift — Structured prompt construction
```

**Key patterns**:
- Enums as namespaces for static functions (`ElementInspectorBridge`, `ElementInspectorPromptBuilder`)
- Value types for data (`ElementInspectorData`), reference types for state (`ElementInspectState`)
- `WeakScriptMessageHandler` proxy to avoid WKWebView retain cycles
- Coordinator pattern for `NSViewRepresentable` lifecycle

## Code Style

- **2-space indentation**, spaces only (no tabs)
- K&R brace style (opening brace on same line)
- `// MARK: - Section` to organize code within files
- `///` doc comments on public API
- File headers: `// FileName.swift // WebInspector // Description`

### Naming

- Types: `PascalCase`
- Functions, variables: `camelCase`
- Booleans: `is`/`has` prefix (`isActive`, `isInputShowing`)

### Access control

- `public` on all API-facing types and methods
- Default `internal` for helpers
- `private` for view subcomponents and state

### SwiftUI

- `@Observable` (not `ObservableObject`)
- `@Bindable` to bind `@Observable` properties
- `@State` / `@FocusState` for local view state
- Custom `ViewModifier` structs exposed via `View` extensions

### Concurrency

- `@MainActor` on observable state classes
- `Sendable` on structs/enums crossing isolation boundaries
- `Task { @MainActor in }` for UI updates from callbacks

## Testing

Uses **Swift Testing** (not XCTest):

```swift
@Suite("SuiteName")
struct SomeTests {
  @Test func descriptiveName() {
    #expect(value == expected)
  }
}
```

- `@MainActor` on suites that test state classes
- Shared fixtures in `TestFixtures` enum (`makeButton()`, `makeMinimalDiv()`)
- One test file per source type
- `// MARK: -` sections to group related tests

## Two Inspector Modes

- **Input mode** (`.input`): select element → type instruction → submit via `onSubmit`
- **Context mode** (`.context`): select element → data sent immediately via `onContextSelection` → auto-dismiss
