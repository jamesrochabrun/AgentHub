# AgentHub — Agent Guidelines

## Architecture Overview

AgentHub is a native macOS app (SwiftUI, Swift 6.0 tools / `.v5` language mode) that monitors and manages Claude Code and Codex CLI sessions in real-time. Everything runs locally — no data leaves the machine.

### Core Architecture Principles

1. **Protocol-driven services** — Every service is defined as a protocol. Concrete implementations are injected via `AgentHubProvider`. This enables mocking and testability throughout the codebase.
2. **Actor isolation for I/O** — Services performing file or network I/O are Swift actors, ensuring thread safety without manual locking.
3. **@Observable for state** — All observable state uses the `@Observable` macro. Never use `ObservableObject` or `@Published`.
4. **@MainActor ViewModels** — ViewModels are `@MainActor`-isolated and drive the UI layer via SwiftUI bindings.
5. **Composable views** — SwiftUI views are small, focused components. Large views are broken into extracted subviews.

### Data Flow

```
JSONL session files on disk
  → SessionFileWatcher (kqueue DispatchSource, incremental byte-offset reads)
  → SessionJSONLParser (structured state from raw lines)
  → SessionMonitorState (Combine publisher)
  → CLISessionsViewModel (@MainActor, drives UI)
  → SwiftUI Views (composable components)
```

### Provider Abstraction

Claude and Codex are supported through shared protocols:

- `SessionMonitorServiceProtocol` — session discovery and repo management
- `SessionFileWatcherProtocol` — real-time file monitoring
- `SessionSearchServiceProtocol` — full-text search

Concrete types: `CLISessionMonitorService` / `CodexSessionMonitorService`, `SessionFileWatcher` / `CodexSessionFileWatcher`.

## Service Design Rules

- **Always define a protocol first** — never depend on concrete service types directly
- ViewModels and other consumers receive dependencies as protocol types
- `AgentHubProvider` is the service locator; tests substitute mock implementations
- Actors implement protocols for thread-safe I/O; mocks can be plain classes

## CLI Launch & Persistence Invariants

- AI override flags are applied only when starting a new CLI session, never when resuming an existing one
- Empty or unsupported saved provider settings must fall back to the CLI's own defaults instead of emitting override flags
- Session metadata is stored in SQLite via GRDB; schema changes must be added as new `DatabaseMigrator` migrations rather than rewriting existing migrations

```swift
protocol SessionSearchServiceProtocol {
  func search(query: String, in sessions: [CLISession]) async -> [SearchResult]
}
```

## Testing Requirements

- All services and ViewModels **must have unit tests**
- Use protocol-based mocks to isolate the unit under test
- Tests live in `AgentHubTests/` mirroring the source structure
- Use `async` test methods for actor-based services
- Prefer deterministic tests — inject controlled data, don't depend on filesystem state
- Cover critical paths: session discovery, JSONL parsing, state transitions, file watcher lifecycle

## Web Preview Behavior

- Prefer agent-provided localhost URLs for web preview when available
- If monitor state has not populated yet, recover the latest localhost URL directly from the session JSONL file before falling back to static preview
- If an agent-provided localhost preview fails to load, fall back to static HTML in this order: root `index.html`, then other discovered HTML files
- Changes to web preview precedence or fallback behavior must include unit tests

## SwiftUI View Guidelines

- Views must be **small, focused, and composable** — one responsibility per view
- When a view body exceeds ~40–50 lines, extract subviews into dedicated structs
- Extract repeated patterns into reusable components (e.g., `StatusBadge`, `SectionHeader`)
- Use `ViewModifier` for shared styling and behavior
- Keep business logic in ViewModels — views handle layout and presentation only
- Use `@Environment` for shared dependencies; avoid passing services through many init layers
- Use `@Binding` for two-way parent-child data flow
- Name views descriptively: `SessionStatusIndicator` not `StatusView`

## Code Style

- 2-space indentation (no tabs)
- `@Observable` macro — never `ObservableObject`
- `async/await` and actors — never completion handlers
- `@MainActor` on ViewModels and UI-bound classes
- UserDefaults keys namespaced under `com.agenthub.`

## Git Commits

- Never add "Co-Authored-By: Claude" or any Claude co-author line
