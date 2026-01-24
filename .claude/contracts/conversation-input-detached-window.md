# Contract: Conversation Input and Detached Window Support

**ID**: CONV-INPUT-001
**Created**: 2026-01-24
**Status**: COMPLETE
**Owner**: feature-owner

---

## Problem Statement

The SessionConversationView was added in commit 6f2aedc but currently only displays messages - there's no way for users to send messages to Claude Code from the conversation view. Additionally, the SessionDetailWindow (detached session window) is hardcoded to terminal mode (`viewMode: .terminal` on line 46), so users cannot use the conversation view in detached windows.

Users need:
1. A text input field to send messages to Claude from the conversation view
2. The ability to switch between conversation and terminal views in detached windows

---

## Acceptance Criteria

| # | Criterion | Verified |
|---|-----------|----------|
| AC1 | SessionConversationView has a text input field at the bottom that sends messages to Claude Code when submitted | [x] |
| AC2 | SessionDetailWindow supports the conversation/terminal view mode toggle (matching the main MonitoringCardView behavior) | [x] |
| AC3 | Messages sent from conversation view input appear in the session and trigger Claude Code responses | [x] |

_Max 3 criteria. Each must be binary (done/not done)._

---

## Scope

### In Scope
- Add text input field to SessionConversationView with send functionality
- Add view mode toggle to SessionDetailWindow header (conversation/terminal)
- Wire text input to existing ClaudeCode client message sending
- Match the visual style of existing UI components

### Out of Scope
- Changes to the terminal view itself
- Message history persistence beyond current session
- Rich text input (markdown preview, file attachments)
- Changes to ConversationMessage model

---

## Technical Design

### Files to Modify

| File | Changes |
|------|---------|
| `app/modules/AgentHubCore/Sources/AgentHub/UI/SessionConversationView.swift` | Add text input field at bottom with TextField, send button, and callback for message submission |
| `app/modules/AgentHubCore/Sources/AgentHub/UI/SessionDetailWindow.swift` | Add view mode state, pass correct viewMode to SessionMonitorPanel, add toggle in header |

### Files to Create

_None required - all changes are to existing files._

### Key Interfaces

```swift
// SessionConversationView - Add input parameters
public struct SessionConversationView: View {
  let messages: [ConversationMessage]
  let scrollToBottom: Bool
  let onSendMessage: ((String) -> Void)?  // NEW: Callback for sending messages

  public init(
    messages: [ConversationMessage],
    scrollToBottom: Bool = true,
    onSendMessage: ((String) -> Void)? = nil  // NEW
  )
}

// SessionDetailWindow - Add view mode tracking
public struct SessionDetailWindow: View {
  let sessionId: String
  @State private var viewMode: SessionViewMode = .conversation  // NEW: Local view mode state

  // Header will include toggle similar to MonitoringCardView lines 293-333
}
```

### Data Flow

1. **Conversation Input Flow**:
   - User types in TextField at bottom of SessionConversationView
   - User presses Enter or clicks Send button
   - `onSendMessage` callback invoked with message text
   - Parent view (SessionMonitorPanel) passes message to TerminalContainerView via `sendPromptIfNeeded`
   - Terminal sends text + carriage return to Claude process (existing pattern from EmbeddedTerminalView.swift:182-194)

2. **View Mode Toggle Flow (Detached Window)**:
   - User clicks conversation or terminal button in header
   - Local `@State viewMode` updated
   - SessionMonitorPanel receives new viewMode and switches display
   - View mode persisted via CLISessionsViewModel if viewModel available

---

## Patchset Protocol

| PS | Gate | Deliverables | Status |
|----|------|--------------|--------|
| 1 | Models compile | No new models needed - using existing interfaces | [x] |
| 2 | UI wired | Text input in conversation view, toggle in detached window | [x] |
| 2.5 | Design bar | ui-polish SHIP YES | [x] |
| 3 | Logic complete | Message sending wired to terminal, view mode toggle functional | [x] |
| 4 | Polish | Clean build, no warnings | [x] |

### PS1 Checklist
- [x] All new types are Sendable (N/A - no new types)
- [x] Services are actors (N/A - no new services)
- [x] Error types defined (N/A - no new errors)
- [x] Build succeeds

### PS2 Checklist
- [x] Views created and navigable
- [x] State wired to views
- [x] Build succeeds

### PS2.5 Checklist (UI only)
- [x] Ruthless simplicity
- [x] One clear primary action
- [x] Strong visual hierarchy
- [x] No clutter
- [x] Native macOS feel

### PS3 Checklist
- [x] Business logic implemented
- [x] Error handling complete
- [x] Edge cases covered

### PS4 Checklist
- [x] No compiler warnings
- [x] No debug statements
- [x] Code is clean

---

## Context7 Attestation

_MANDATORY: Agents must check Context7 docs before using ALL APIs (training data is outdated). Claude is especially weak on Swift - ALWAYS verify._

### Required Libraries (planner fills)

| Library | Context7 ID | Why Needed |
|---------|-------------|------------|
| SwiftUI | /apple/swiftui | TextField, Button, view modifiers, @State, @FocusState |

### Agent Reports (each agent fills their section)

**feature-owner**:
| Library | Query | Result |
|---------|-------|--------|
| SwiftUI | TextField FocusState onSubmit keyboard handling macOS submit on enter key | Verified: Use @FocusState for focus, onSubmit modifier for Enter key handling |

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
│ agenthub-explorer │ ─── Gathers context (if unfamiliar area)
└────────┬──────────┘
         │ SKIPPED - manager provided sufficient context
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
| agenthub-explorer | Context gathering | [x] Skipped - context provided by manager |
| feature-owner | Implementation PS1-4 | [x] Done |
| ui-polish | Design review PS2.5 | [x] Done |
| integrator | Final gate | [x] Done |

---

## Blockers & Decisions

| Date | Issue | Decision | Decided By |
|------|-------|----------|------------|
| | | | |

---

## Implementation Notes

### Key Patterns from Codebase

1. **Message Sending Pattern** (from EmbeddedTerminalView.swift:182-194):
   ```swift
   func sendPromptIfNeeded(_ prompt: String) {
     guard !promptSent, let terminal = terminalView else { return }
     promptSent = true
     terminal.send(txt: prompt)
     Task { @MainActor [weak terminal] in
       try? await Task.sleep(for: .milliseconds(100))
       terminal?.send([13])  // ASCII 13 = carriage return (Enter key)
     }
   }
   ```

2. **View Mode Toggle Pattern** (from MonitoringCardView.swift:293-333):
   - Segmented control with capsule background
   - Uses `withAnimation(.easeInOut(duration: 0.2))`
   - Conversation icon: `bubble.left.and.bubble.right`
   - Terminal icon: `terminal`

3. **SessionMonitorPanel Integration**:
   - Already supports `viewMode: SessionViewMode` parameter
   - Already supports `claudeClient` and `terminalKey` for sending messages
   - Conversation view shows when `viewMode == .conversation && !showTerminal`

### SessionDetailWindow Changes Needed

Line 46 currently hardcodes:
```swift
viewMode: .terminal,
```

Should become dynamic with local state synced to viewModel if available.

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

### Implementation Quality
- Clean separation of concerns: input field is contained in SessionConversationView, message routing handled by parent components
- Consistent UX patterns: view mode toggle matches MonitoringCardView design
- Proper state management: viewMode synced with CLISessionsViewModel when available
- Thread-safe message sending: uses existing TerminalContainerView.sendMessage pattern

### Key Learnings
- The existing architecture made this feature straightforward - no architectural changes needed
- EmbeddedTerminalView already had sendMessage method (line 200), making message routing clean
- SessionMonitorPanel's ZStack pattern preserves terminal state when switching views
- Design bar approval (ui-polish SHIP YES) caught color consistency issues early

### Future Considerations
- Consider adding message history persistence beyond current session
- Rich text input (markdown preview) could enhance UX in future iterations
- File attachment support would be valuable for code sharing
