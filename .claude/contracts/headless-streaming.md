# Contract: Claude Code Headless Mode Streaming

**ID**: HS-001
**Created**: 2026-01-24
**Status**: COMPLETE
**Owner**: feature-owner

---

## Problem Statement

AgentHub currently runs Claude Code in an interactive PTY terminal (SwiftTerm). This architecture causes significant UX issues:

1. **ConversationView lag**: Updates from JSONL file watching arrive 200-1000ms behind the terminal
2. **Data sync issues**: Two parallel data sources (PTY rendering vs JSONL file watching) can get out of sync
3. **No true streaming**: The terminal renders immediately, but our UI lags behind

**Goal**: Implement real-time streaming like Conductor.build using Claude Code's headless mode, where events stream directly from stdout JSONL and render immediately in a custom conversation UI.

---

## Acceptance Criteria

| # | Criterion | Verified |
|---|-----------|----------|
| AC1 | Real-time streaming: Text appears as Claude generates (no perceptible lag vs terminal) | [x] |
| AC2 | Tool visibility: See tool calls as they happen with UI for approval/denial | [x] |
| AC3 | Session persistence: Resume sessions across prompts using --resume flag | [x] |

_Max 3 criteria. Each must be binary (done/not done)._

---

## Scope

### In Scope
- New `ClaudeHeadlessService` actor for process spawning and JSONL parsing
- Event type definitions matching Claude Code's stream-json output
- Real-time event streaming via `AsyncThrowingStream`
- Tool approval UI for permission prompts (control_request events)
- Session state management (session ID tracking, resume capability)
- New conversation UI for headless mode output
- Integration with existing CLISessionsViewModel

### Out of Scope
- Removing existing terminal view (keep as fallback/debug option)
- Image/attachment support in messages (future enhancement)
- Long-running tool streaming (Bash output streaming - future enhancement)
- Token usage display (can be added later)
- Multiple concurrent sessions (one session at a time for now)

---

## Technical Design

### Files to Create

| File | Purpose |
|------|---------|
| `Services/ClaudeHeadlessService.swift` | Actor for process spawning, JSONL parsing, stdin writing |
| `Models/ClaudeEvent.swift` | Event type definitions (system, assistant, toolResult, etc.) |
| `Models/ClaudeSession.swift` | Session state (sessionId, isProcessing, messages) |
| `UI/HeadlessConversationView.swift` | Main conversation UI for headless mode |
| `UI/ToolApprovalSheet.swift` | Permission prompt UI for control_request events |
| `UI/AssistantMessageView.swift` | Message bubble rendering (text + tool_use blocks) |
| `ViewModels/HeadlessSessionViewModel.swift` | Observable state for conversation UI |

### Files to Modify

| File | Changes |
|------|---------|
| `CLISessionsViewModel.swift` | Add headless mode toggle, integrate with HeadlessSessionViewModel |
| `SessionDetailView.swift` | Conditionally use HeadlessConversationView vs terminal |
| `AgentHubProvider.swift` | Add `ClaudeHeadlessService` to dependency container |

### Key Interfaces

```swift
// LOCKED: Do not change signatures without contract amendment

// Models/ClaudeEvent.swift
public enum ClaudeEvent: Sendable {
    case system(ClaudeSystemEvent)
    case assistant(ClaudeAssistantEvent)
    case toolResult(ClaudeToolResultEvent)
    case controlRequest(ClaudeControlRequestEvent)
    case result(ClaudeResultEvent)
    case unknown
}

public struct ClaudeSystemEvent: Codable, Sendable {
    public let subtype: String?
    public let sessionId: String?
    public let model: String?
    public let tools: [String]?
    public let cwd: String?
}

public struct ClaudeAssistantEvent: Codable, Sendable {
    public let message: ClaudeMessage?
    public let sessionId: String?
    public let error: String?
}

public struct ClaudeMessage: Codable, Sendable {
    public let id: String?
    public let role: String?
    public let content: [ClaudeContentBlock]?
    public let stopReason: String?
}

public enum ClaudeContentBlock: Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AnyCodable])
}

public struct ClaudeToolResultEvent: Codable, Sendable {
    public let toolUseId: String?
    public let content: String?
    public let isError: Bool?
}

public struct ClaudeControlRequestEvent: Codable, Sendable {
    public let requestId: String
    public let request: ClaudeControlRequest
}

public enum ClaudeControlRequest: Codable, Sendable {
    case canUseTool(toolName: String, input: [String: AnyCodable], toolUseId: String?)
    case hookCallback(callbackId: String, input: [String: AnyCodable])
}

public struct ClaudeResultEvent: Codable, Sendable {
    public let result: String?
    public let isError: Bool?
    public let sessionId: String?
    public let usage: ClaudeUsage?
}

public struct ClaudeUsage: Codable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
}

// Services/ClaudeHeadlessService.swift
public actor ClaudeHeadlessService {

    /// Start a headless Claude session
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - sessionId: Optional session ID to resume
    ///   - workingDirectory: Working directory for Claude
    /// - Returns: Async stream of Claude events
    public func start(
        prompt: String,
        sessionId: String?,
        workingDirectory: URL
    ) async throws -> AsyncThrowingStream<ClaudeEvent, Error>

    /// Send control response (for tool approval)
    public func sendControlResponse(
        requestId: String,
        allow: Bool,
        updatedInput: [String: Any]?
    ) async throws

    /// Stop the current process
    public func stop() async
}

// ViewModels/HeadlessSessionViewModel.swift
@MainActor
@Observable
public final class HeadlessSessionViewModel {
    public var messages: [ConversationMessage] = []
    public var pendingToolApproval: ClaudeControlRequestEvent?
    public var isProcessing: Bool = false
    public var sessionId: String?
    public var error: String?

    public func startSession(prompt: String, workingDirectory: URL) async
    public func resumeSession(prompt: String, sessionId: String, workingDirectory: URL) async
    public func approveToolUse(requestId: String) async
    public func denyToolUse(requestId: String) async
    public func cancel() async
}
```

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                 HeadlessConversationView                         │
│  - Displays messages                                             │
│  - Shows tool approval sheet when pendingToolApproval != nil     │
│  - Input field for prompts                                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 HeadlessSessionViewModel                         │
│  @Observable, @MainActor                                         │
│  - Maintains conversation state                                  │
│  - Consumes AsyncThrowingStream<ClaudeEvent, Error>             │
│  - Dispatches tool approval responses                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ClaudeHeadlessService                         │
│  actor                                                           │
│  - Spawns Process with headless flags                           │
│  - Parses stdout JSONL line-by-line                             │
│  - Writes control responses to stdin                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Process                                  │
│  claude -p "prompt" --output-format stream-json --verbose       │
│         --permission-prompt-tool stdio --input-format stream-json│
│  stdin:  control_response JSON                                   │
│  stdout: JSONL event stream                                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Patchset Protocol

| PS | Gate | Deliverables | Status |
|----|------|--------------|--------|
| 1 | Models compile | ClaudeEvent.swift, ClaudeSession.swift, ClaudeHeadlessService stub | [x] |
| 2 | UI wired | HeadlessConversationView, ToolApprovalSheet, basic navigation | [x] |
| 2.5 | Design bar | ui-polish SHIP YES for conversation UI | [x] |
| 3 | Logic complete | Full JSONL parsing, process management, tool approval flow | [x] |
| 4 | Polish | Integration with CLISessionsViewModel, clean build | [x] |

### PS1 Checklist
- [ ] ClaudeEvent enum with all event types (Codable, Sendable)
- [ ] ClaudeSession model for state tracking (Sendable)
- [ ] ClaudeHeadlessService actor with method stubs
- [ ] Error types defined (ClaudeHeadlessError)
- [ ] Added to AgentHubProvider
- [ ] Build succeeds

### PS2 Checklist
- [ ] HeadlessConversationView showing messages list
- [ ] AssistantMessageView for text and tool_use rendering
- [ ] ToolApprovalSheet for control_request prompts
- [ ] HeadlessSessionViewModel with @Observable state
- [ ] Basic navigation wiring in SessionDetailView
- [ ] Build succeeds

### PS2.5 Checklist (UI only)
- [ ] Ruthless simplicity - no unnecessary elements
- [ ] One clear primary action - prompt input is focus
- [ ] Strong visual hierarchy - messages, tools, input clearly distinguished
- [ ] No clutter - clean conversation layout
- [ ] Native macOS feel - follows system conventions

### PS3 Checklist
- [x] Process spawning with correct CLI flags
- [x] JSONL parsing via FileHandle.bytes.lines
- [x] AsyncThrowingStream yielding ClaudeEvent
- [x] Control response writing to stdin
- [x] Session ID extraction and storage
- [x] Error handling (auth failure, process crash, parse errors)
- [x] Cancellation support

### PS4 Checklist
- [ ] No compiler warnings
- [ ] No debug statements (use AppLogger)
- [ ] CLISessionsViewModel integration complete
- [ ] Toggle between headless and terminal modes
- [ ] Clean build

---

## Context7 Attestation

_MANDATORY: Agents must check Context7 docs before using ALL APIs (training data is outdated). Claude is especially weak on Swift - ALWAYS verify._

### Required Libraries (planner fills)

| Library | Context7 ID | Why Needed |
|---------|-------------|------------|
| SwiftUI | /websites/developer_apple_swiftui | Views, @Observable, environment |
| Swift Foundation | /swiftlang/swift-foundation | Process, Pipe, FileHandle, Codable |
| Swift Concurrency | (part of Swift stdlib) | AsyncThrowingStream, actors, Task |

### Agent Reports (each agent fills their section)

**feature-owner**:
| Library | Query | Result |
|---------|-------|--------|
| /swiftlang/swift-foundation | Process spawn FileHandle bytes lines async streaming | Found proposal docs for Subprocess API |
| /swiftlang/swift | AsyncThrowingStream continuation yield finish | Found SIL-level docs on async continuation |

**ui-polish**:
| Library | Query | Result |
|---------|-------|--------|
| _fill if API used_ | | |

**swift-debugger** (if invoked):
| Library | Query | Result |
|---------|-------|--------|
| _fill if investigating API_ | | |

---

## Agent Workflow

_Note: The **planner** creates this contract and orchestrates execution. It is not listed below because it operates outside the contract - agents below execute against the contract._

```
┌───────────────────┐
│ agenthub-explorer │ ─── Read existing services for patterns (optional)
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│   feature-owner   │ ─── PS1 → PS2 → PS3 → PS4
└────────┬──────────┘
         │
         ▼ (after PS2)
┌───────────────────┐
│     ui-polish     │ ─── PS2.5: SHIP YES / SHIP NO
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│    integrator     │ ─── Final verification
└───────────────────┘
```

### Agent Assignments

| Agent | Responsibility | Status |
|-------|---------------|--------|
| agenthub-explorer | Context gathering (existing service patterns) | [x] Skipped |
| feature-owner | Implementation PS1-4 | [x] Done |
| ui-polish | Design review PS2.5 | [x] Done |
| integrator | Final gate | [x] Done |

---

## Blockers & Decisions

| Date | Issue | Decision | Decided By |
|------|-------|----------|------------|
| 2026-01-24 | Keep terminal view? | Yes, as fallback/debug option | Planner |
| 2026-01-24 | Tool approval UI style | Sheet presentation (not inline) | Planner |
| 2026-01-24 | Long-running tool streaming | Out of scope for v1 | Planner |

---

## Sign-off

| Role | Signature | Date |
|------|-----------|------|
| feature-owner | [x] PS1-4 complete | 2026-01-24 |
| ui-polish | [x] SHIP YES | 2026-01-24 |
| integrator | [x] VERIFIED | 2026-01-24 |

**Contract Completion**: 2026-01-24

---

## Post-Completion Notes

_After COMPLETE: What did we learn? What would we do differently?_

---

## Reference Material

### CLI Invocation Pattern
```bash
# Single prompt with tool approval support
claude -p "your prompt here" \
  --output-format stream-json \
  --verbose \
  --permission-prompt-tool stdio \
  --input-format stream-json

# Resume existing session
claude -p "follow-up prompt" \
  --resume SESSION_ID \
  --output-format stream-json \
  --verbose \
  --permission-prompt-tool stdio \
  --input-format stream-json
```

### Control Response Format
```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req-uuid",
    "response": {"behavior": "allow"}
  }
}
```

### Source References
- Implementation spec: `.claude/prompts/headless-mode-implementation.md`
- Conduit CLI patterns: `.claude/reference/conduit-claude-runner.rs`
- JSONL event types: `.claude/reference/conduit-stream-parser.rs`
