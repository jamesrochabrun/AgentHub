# Contract: Claude Code UI Overlay - Phase 1

**ID**: CCUI-001
**Created**: 2026-01-24
**Status**: COMPLETE
**Owner**: feature-owner

---

## Problem Statement

The current session view uses `EmbeddedTerminalView` (SwiftTerm) which displays raw ANSI terminal output. This is functional but provides a poor user experience:

1. **Readability**: Terminal output is hard to parse visually - tool calls, text, errors all look similar
2. **Navigation**: No way to collapse/expand tool calls or jump to specific messages
3. **Context**: No rich formatting for code diffs, file paths, or markdown content
4. **Aesthetics**: Terminal feels out of place in a modern macOS app

Phase 1 replaces the terminal with a native conversation view that renders messages, tool calls, and activity in a structured, beautiful interface.

---

## Acceptance Criteria

| # | Criterion | Verified |
|---|-----------|----------|
| AC1 | `SessionConversationView` displays user messages, assistant text, and tool calls parsed from the session JSONL | [x] |
| AC2 | Tool call cards are collapsible and show tool name, input summary, and success/failure status | [x] |
| AC3 | Toggle button switches between terminal view (existing) and conversation view (new) without losing state | [x] |

_Max 3 criteria. Each must be binary (done/not done)._

---

## Scope

### In Scope
- New `SessionConversationView` that renders conversation from JSONL data
- New `ConversationMessage` model representing parsed messages for UI display
- New `ToolCallCard` view for displaying tool invocations with collapse/expand
- New `ConversationMessageView` for rendering different message types
- View mode toggle (terminal vs conversation) in `SessionMonitorPanel`
- Integration with existing `SessionFileWatcher` for real-time updates
- Scroll-to-bottom behavior for new messages

### Out of Scope
- Markdown rendering in assistant messages (Phase 2)
- Syntax-highlighted code diffs (Phase 2)
- Settings panel for Claude Code configuration (Phase 3)
- Input area for sending messages (Phase 3)
- File tree view (Phase 4)
- Search within conversation (Phase 4)

---

## Technical Design

### Files to Modify

| File | Changes |
|------|---------|
| `UI/SessionMonitorPanel.swift` | Add view mode toggle button, conditionally show conversation or terminal |
| `ViewModels/CLISessionsViewModel.swift` | Add `sessionViewModes: [String: SessionViewMode]` to track per-session view preference |
| `Models/SessionMonitorState.swift` | Expose `recentActivities` in a format suitable for conversation rendering |

### Files to Create

| File | Purpose |
|------|---------|
| `Models/ConversationMessage.swift` | Message model with user/assistant/toolUse/toolResult/thinking variants |
| `UI/SessionConversationView.swift` | Main conversation view with ScrollViewReader |
| `UI/ConversationMessageView.swift` | Renders individual messages based on type |
| `UI/ToolCallCard.swift` | Expandable card for tool invocations |
| `UI/UserMessageBubble.swift` | Styled bubble for user messages |
| `UI/AssistantMessageView.swift` | View for assistant text responses |
| `Services/ConversationParser.swift` | Transforms `SessionJSONLParser.ParseResult` activities into `ConversationMessage` array |

### Key Interfaces

```swift
// Models/ConversationMessage.swift
public struct ConversationMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let content: MessageContent

  public enum MessageContent: Equatable, Sendable {
    case user(text: String)
    case assistant(text: String)
    case toolUse(name: String, input: String?, id: String)
    case toolResult(name: String, success: Bool, toolUseId: String)
    case thinking
  }
}

// Services/ConversationParser.swift
public struct ConversationParser {
  /// Converts activity entries from SessionJSONLParser into conversation messages
  public static func parse(activities: [ActivityEntry]) -> [ConversationMessage]
}

// UI/SessionConversationView.swift
public struct SessionConversationView: View {
  let messages: [ConversationMessage]
  let scrollToBottom: Bool

  public var body: some View { /* ScrollView with ForEach */ }
}

// UI/ToolCallCard.swift
public struct ToolCallCard: View {
  let toolName: String
  let input: String?
  let result: ToolResult?
  @State private var isExpanded: Bool = false

  public enum ToolResult: Equatable {
    case pending
    case success
    case failure
  }
}

// ViewModels/CLISessionsViewModel.swift additions
public enum SessionViewMode: String, Sendable {
  case terminal
  case conversation
}

// Add to CLISessionsViewModel:
public var sessionViewModes: [String: SessionViewMode] = [:]

public func toggleViewMode(for sessionId: String) {
  let current = sessionViewModes[sessionId] ?? .terminal
  sessionViewModes[sessionId] = (current == .terminal) ? .conversation : .terminal
}

public func viewMode(for sessionId: String) -> SessionViewMode {
  sessionViewModes[sessionId] ?? .terminal
}
```

### Data Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                     Session JSONL File                            │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│                   SessionFileWatcher                              │
│   (Watches file, parses lines, emits state updates)              │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│                 SessionMonitorState                               │
│   (Contains recentActivities: [ActivityEntry])                   │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│                  ConversationParser                               │
│   (Transforms ActivityEntry[] → ConversationMessage[])           │
└───────────────────────────────┬──────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│                SessionConversationView                            │
│   (ScrollView rendering ConversationMessageView for each)        │
└──────────────────────────────────────────────────────────────────┘
```

---

## Patchset Protocol

| PS | Gate | Deliverables | Status |
|----|------|--------------|--------|
| 1 | Models compile | `ConversationMessage.swift`, `ConversationParser.swift` | [x] |
| 2 | UI wired | `SessionConversationView`, `ToolCallCard`, toggle in `SessionMonitorPanel` | [x] |
| 2.5 | Design bar | ui-polish SHIP YES | [x] |
| 3 | Logic complete | Real-time updates, scroll behavior, state persistence | [x] |
| 4 | Polish | Clean build, no warnings, previews working | [x] |

### PS1 Checklist
- [x] `ConversationMessage` struct is Sendable
- [x] `ConversationParser` transforms ActivityEntry to ConversationMessage correctly
- [x] `SessionViewMode` enum added to CLISessionsViewModel
- [x] Build succeeds with new models

### PS2 Checklist
- [x] `SessionConversationView` renders list of messages
- [x] `ToolCallCard` shows tool name with expand/collapse
- [x] `UserMessageBubble` styled appropriately
- [x] `AssistantMessageView` displays text
- [x] Toggle button added to `SessionMonitorPanel`
- [x] View mode state persisted per-session in viewModel
- [x] Build succeeds

### PS2.5 Checklist (UI only)
- [x] Ruthless simplicity - no unnecessary elements
- [x] One clear primary action - conversation is the focus
- [x] Strong visual hierarchy - messages clearly distinguished
- [x] No clutter - appropriate spacing and whitespace
- [x] Native macOS feel - follows HIG, uses system components

### PS3 Checklist
- [x] Conversation updates in real-time as JSONL changes
- [x] Scroll-to-bottom works for new messages
- [x] Tool call matching (toolUse → toolResult) displays correctly
- [x] View mode persists across app restarts (UserDefaults)
- [x] Edge cases handled (empty conversation, long messages, etc.)

### PS4 Checklist
- [x] No compiler warnings (in new/modified files)
- [x] No debug print statements
- [x] All previews render correctly (verified structure)
- [x] Code documented with /// comments

---

## Context7 Attestation

_MANDATORY: Agents must check Context7 docs before using ALL APIs (training data is outdated). Claude is especially weak on Swift - ALWAYS verify._

### Required Libraries (planner fills)

| Library | Context7 ID | Why Needed |
|---------|-------------|------------|
| SwiftUI | /websites/developer_apple_swiftui | ScrollViewReader, LazyVStack, view modifiers |
| Foundation | (standard library) | Date formatting, UUID |

### Agent Reports (each agent fills their section)

**feature-owner**:
| Library | Query | Result |
|---------|-------|--------|
| SwiftUI | ScrollView ScrollViewReader LazyVStack scrollTo | Verified: Use @Namespace for IDs, proxy.scrollTo() in onChange |
| SwiftUI | View modifiers, state management | Verified: @State for local, viewModel for persistent |
| SwiftUI | onChange(of:initial:_:) | PS3: Verified: onChange tracks value changes, supports old/new params |

**ui-polish**:
| Library | Query | Result |
|---------|-------|--------|
| SwiftUI | View composition, layout | Verified: Standard patterns used |

**swift-debugger** (if invoked):
| Library | Query | Result |
|---------|-------|--------|
| _fill if investigating API_ | | |

---

## Agent Workflow

_Note: The **planner** creates this contract and orchestrates execution. It is not listed below because it operates outside the contract - agents below execute against the contract._

```
┌───────────────────┐
│ agenthub-explorer │ ─── Gathers context (if unfamiliar area)
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│   feature-owner   │ ─── PS1 → PS2 → PS3 → PS4
└────────┬──────────┘
         │
         ▼ (after PS2, if UI changes)
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
| agenthub-explorer | Context gathering | [x] Done (research provided in prompt) |
| feature-owner | Implementation PS1-4 | [x] Done |
| ui-polish | Design review PS2.5 | [x] Done |
| integrator | Final gate | [x] Done |

---

## Blockers & Decisions

| Date | Issue | Decision | Decided By |
|------|-------|----------|------------|
| 2026-01-24 | Should we parse full JSONL or reuse ActivityEntry? | Reuse ActivityEntry from SessionMonitorState - already parsed and real-time | planner |
| 2026-01-24 | How many activities to show? | Keep existing 100 limit in recentActivities, may increase in Phase 2 | planner |
| 2026-01-24 | Default view mode? | Conversation (new default) - better UX for new users, terminal still available | feature-owner (PS3) |

---

## Sign-off

| Role | Signature | Date |
|------|-----------|------|
| feature-owner | [x] PS1-4 complete | 2026-01-24 |
| ui-polish | [x] SHIP YES | 2026-01-24 |
| integrator | [x] VERIFIED | 2026-01-24 |

**Contract Completion**: COMPLETE

---

## Post-Completion Notes

**Integrator Verification (2026-01-24)**

All acceptance criteria verified as PASS:

**AC1**: SessionConversationView displays user messages, assistant text, and tool calls - PASS
- ConversationMessage model properly defined with all message types (user, assistant, toolUse, toolResult, thinking)
- ConversationParser correctly transforms ActivityEntry to ConversationMessage
- SessionConversationView renders all message types using ConversationMessageView router
- Empty state handled with appropriate messaging

**AC2**: Tool call cards are collapsible and show tool name, input summary, success/failure status - PASS
- ToolCallCard implements expand/collapse with @State isExpanded
- Shows tool name, input preview (truncated when collapsed), and timestamp
- Status icons and colors correctly map to pending/success/failure states
- Tool result matching works via buildToolResultMap in SessionConversationView

**AC3**: Toggle button switches between terminal and conversation view without losing state - PASS
- SessionViewMode enum added with terminal/conversation cases
- CLISessionsViewModel tracks per-session view modes with sessionViewModes dictionary
- View mode persisted to UserDefaults via AgentHubDefaults.sessionViewModes
- SessionMonitorPanel uses ZStack with opacity to preserve both views (prevents state loss)
- Default view mode is conversation (better UX for new users)
- MonitoringCardView and SessionDetailWindow properly integrate view mode toggle

**Build Verification**: PASS
- Full build succeeds with no errors
- All new files compile correctly
- Integration with existing codebase verified
- Color.Chat palette exists and provides all required colors

**Code Quality**: PASS
- All files properly documented with /// comments
- Models are Sendable and Codable where appropriate
- Services follow actor pattern for thread safety
- UI follows SwiftUI best practices (ScrollViewReader, LazyVStack, onChange)
- No debug print statements found
- Preview code included for all UI components

**Contract Completion**: All patchsets (PS1-PS4) complete, all checklists verified, all acceptance criteria met.

**Final Verdict**: VERIFIED - Implementation ready for production use.

---

## Reference: Existing Code Patterns

### ActivityEntry (already available)
```swift
public struct ActivityEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let type: ActivityType
  public let description: String
  public let toolInput: CodeChangeInput?
}

public enum ActivityType: Equatable, Sendable {
  case toolUse(name: String)
  case toolResult(name: String, success: Bool)
  case userMessage
  case assistantMessage
  case thinking
}
```

### SessionMonitorPanel Toggle Pattern
The existing panel uses ZStack with opacity to preserve terminal state:
```swift
ZStack {
  // Activity list
  Group { ... }
    .opacity(showTerminal ? 0 : 1)

  // Terminal view
  EmbeddedTerminalView(...)
    .opacity(showTerminal ? 1 : 0)
}
```

Apply same pattern for conversation view:
```swift
ZStack {
  // Conversation view (new)
  SessionConversationView(...)
    .opacity(viewMode == .conversation ? 1 : 0)

  // Terminal view (existing)
  EmbeddedTerminalView(...)
    .opacity(viewMode == .terminal ? 1 : 0)
}
```
