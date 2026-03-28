# Canvas — Agent Guidelines

Instructions for AI coding agents (Claude Code, Codex, Copilot, etc.) working on this project.

## Before You Start

1. Read `CLAUDE.md` for build commands, architecture, and code style.
2. Run `swift build` to verify the project compiles before making changes.
3. Run `swift test` after every change to catch regressions.

## Making Changes

### Adding a new source file

1. Place it in `Sources/Canvas/`.
2. Follow the file header convention:
   ```swift
   //
   //  FileName.swift
   //  WebInspector
   //
   //  Brief description of what this file does.
   //
   ```
3. Use `// MARK: -` sections to organize code.
4. Mark public API with `public`. Keep internal helpers `internal` or `private`.

### Adding a new test file

1. Place it in `Tests/CanvasTests/`.
2. Use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest.
3. Import with `@testable import Canvas`.
4. Add `@MainActor` to suites that test `@MainActor` types.
5. Use `TestFixtures` for reusable element data (see `CanvasTests.swift`).

### Modifying the inspector pipeline

The data flow is:

```
JS click → WKScriptMessageHandler → ElementInspectorBridge.parseElementData()
  → ElementInspectState.selectElement() → WebInspectorOverlay shows UI
  → onSubmit / onContextSelection callback → ElementInspectorPromptBuilder
```

- **State changes** go in `ElementInspectState`.
- **JS behavior** goes in `ElementInspectorBridge` (the JS string in `userScript`).
- **Parsing** goes in `ElementInspectorBridge.parseElementData()`.
- **UI** goes in `WebInspectInputView`, `WebInspectContextView`, or `WebInspectorOverlay`.
- **Prompt formatting** goes in `ElementInspectorPromptBuilder`.

### Style rules

- 2-space indentation, no tabs.
- `@Observable` for state — never `ObservableObject`.
- `@MainActor` on state classes. `Sendable` on data types.
- Prefer value types (structs/enums) over classes unless observable state is needed.
- Use `///` doc comments on public API. Skip comments on obvious code.
- No force unwraps in production code. Use `guard`/`if let` or nil coalescing.

## Do Not

- Add external dependencies without discussion. This package has zero dependencies.
- Use XCTest. The project uses Swift Testing exclusively.
- Add `Co-Authored-By` lines to commits.
- Create documentation files (README updates, etc.) unless explicitly asked.
- Over-engineer: no abstractions for one-time operations, no speculative features.

## Verification Checklist

Before considering a task complete:

- [ ] `swift build` succeeds
- [ ] `swift test` passes (all 49+ tests)
- [ ] New public API has `///` doc comments
- [ ] New logic has corresponding tests
- [ ] No compiler warnings introduced
