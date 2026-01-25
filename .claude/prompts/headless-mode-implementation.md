# Headless Mode Implementation Prompt

## Mission

Implement Claude Code headless mode streaming for AgentHub, replacing the current PTY terminal approach with a custom conversation UI that receives real-time streaming JSON events directly from Claude Code CLI.

## Why This Change

Currently AgentHub runs Claude Code in an interactive PTY terminal (SwiftTerm). This means:
- ConversationView gets updates from JSONL file watching (200-1000ms lag)
- No native streaming - the terminal renders, but our UI lags behind
- Two parallel data sources that can get out of sync

Conductor.build and Conduit CLI solve this by using **headless mode**:
- Run Claude with `-p` flag (non-interactive)
- Use `--output-format stream-json` for JSONL streaming to stdout
- Parse events in real-time and render in custom UI
- TRUE instant streaming

## Technical Implementation

### CLI Invocation Pattern

```bash
# Single prompt
claude -p "your prompt here" \
  --output-format stream-json \
  --verbose \
  --permission-mode default \
  --allowedTools "Read,Edit,Write,Bash,Glob,Grep"

# Resume existing session
claude -p "follow-up prompt" \
  --resume SESSION_ID \
  --output-format stream-json \
  --verbose

# For tool approval via stdin (interactive tools like AskUserQuestion)
claude -p "prompt" \
  --output-format stream-json \
  --verbose \
  --permission-prompt-tool stdio \
  --input-format stream-json
```

### JSONL Event Types

Each line of stdout is a JSON object with a `type` field:

```swift
enum ClaudeEventType: String, Codable {
    case system      // Init event with session_id, model, tools
    case assistant   // Text output and tool_use blocks
    case toolUse     // Tool invocation (legacy format)
    case toolResult  // Tool completion
    case user        // User message with tool results
    case controlRequest // Permission prompts (can_use_tool, hook_callback)
    case result      // Turn completion with usage stats
}
```

#### System Init Event
```json
{
  "type": "system",
  "subtype": "init",
  "session_id": "uuid-here",
  "model": "claude-sonnet-4-5-20250929",
  "tools": ["Read", "Edit", "Write", "Bash", ...],
  "cwd": "/path/to/workspace"
}
```

#### Assistant Event (text + tool_use)
```json
{
  "type": "assistant",
  "message": {
    "id": "msg-id",
    "role": "assistant",
    "content": [
      {"type": "text", "text": "Let me read that file..."},
      {"type": "tool_use", "id": "tool-id", "name": "Read", "input": {"file_path": "/path"}}
    ],
    "stop_reason": "tool_use"
  },
  "session_id": "uuid"
}
```

#### Tool Result Event
```json
{
  "type": "tool_result",
  "tool_use_id": "tool-id",
  "content": "file contents here...",
  "is_error": false
}
```

#### Control Request (Permission Prompt)
```json
{
  "type": "control_request",
  "request_id": "req-uuid",
  "request": {
    "subtype": "can_use_tool",
    "tool_name": "Bash",
    "input": {"command": "rm -rf /"},
    "tool_use_id": "tool-id"
  }
}
```

Response (write to stdin):
```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req-uuid",
    "response": {"behavior": "allow", "updatedInput": {...}}
  }
}
```

#### Result Event (Turn Complete)
```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "Task completed successfully",
  "session_id": "uuid",
  "usage": {"input_tokens": 1000, "output_tokens": 500}
}
```

## Reference Implementation: Conduit CLI (Rust)

Study these files from https://github.com/conduit-cli/conduit:

### src/agent/claude.rs
- `build_command()` - How to construct the CLI invocation
- `convert_event()` - How to map raw events to unified types
- `start()` - Process spawning and stdout parsing
- Control request handling for tool approval

### src/agent/stream.rs
- `ClaudeRawEvent` enum - All event type definitions
- `JsonlStreamParser` - Async line-by-line parsing
- Content block extraction helpers

### src/agent/events.rs
- Unified event types (AgentEvent)
- TokenUsage, AssistantMessageEvent, ToolStartedEvent, etc.

## Files to Modify/Create in AgentHub

### New Files
```
AgentHubCore/Sources/AgentHub/
├── Services/
│   └── ClaudeHeadlessService.swift      # Process spawning, JSONL parsing
├── Models/
│   ├── ClaudeEvent.swift                # Event type definitions
│   └── ClaudeSession.swift              # Session state management
├── UI/
│   ├── HeadlessConversationView.swift   # New conversation UI
│   ├── ToolApprovalSheet.swift          # Permission prompt UI
│   └── AssistantMessageView.swift       # Message bubble rendering
└── ViewModels/
    └── HeadlessSessionViewModel.swift   # Observable state
```

### Files to Modify
```
- CLISessionsViewModel.swift      # Switch from PTY to headless
- SessionDetailView.swift         # Use new conversation view
- EmbeddedTerminalView.swift      # May keep for fallback/debug
```

## Architecture Pattern

```
┌─────────────────────────────────────────────────────────────┐
│                    HeadlessSessionViewModel                  │
│  @Observable, @MainActor                                    │
│  - messages: [ConversationMessage]                          │
│  - currentToolCalls: [ToolCall]                             │
│  - isProcessing: Bool                                       │
│  - sessionId: String?                                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    ClaudeHeadlessService                     │
│  actor                                                       │
│  - spawnProcess(prompt:, sessionId:) async throws           │
│  - parseEventStream(stdout:) -> AsyncStream<ClaudeEvent>    │
│  - sendControlResponse(requestId:, response:) async         │
│  - stopProcess() async                                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        Process                               │
│  claude -p "..." --output-format stream-json --verbose      │
│  stdin: control responses (JSON)                            │
│  stdout: event stream (JSONL)                               │
└─────────────────────────────────────────────────────────────┘
```

## Swift Implementation Patterns

### Event Parsing with AsyncSequence
```swift
func parseEvents(from stdout: FileHandle) -> AsyncThrowingStream<ClaudeEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            for try await line in stdout.bytes.lines {
                guard !line.isEmpty else { continue }
                do {
                    let event = try JSONDecoder().decode(ClaudeEvent.self, from: Data(line.utf8))
                    continuation.yield(event)
                } catch {
                    AppLogger.claude.warning("Failed to parse event: \(error)")
                }
            }
            continuation.finish()
        }
    }
}
```

### Process Management
```swift
public actor ClaudeHeadlessService {
    private var process: Process?
    private var stdinPipe: Pipe?

    public func start(prompt: String, sessionId: String?, workingDirectory: URL) async throws -> AsyncThrowingStream<ClaudeEvent, Error> {
        let process = Process()
        process.executableURL = claudeBinaryURL

        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        if let sessionId {
            args += ["--resume", sessionId]
        }
        process.arguments = args
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe

        return parseEvents(from: stdoutPipe.fileHandleForReading)
    }
}
```

## Acceptance Criteria

1. **Real-time streaming**: Text appears character-by-character as Claude generates
2. **Tool visibility**: See tool calls as they happen (Read, Edit, Bash, etc.)
3. **Tool approval**: UI for approving/denying tool use (especially Bash commands)
4. **Session persistence**: Resume sessions across app restarts
5. **Error handling**: Graceful handling of process failures, auth errors
6. **Token tracking**: Display usage stats from result events

## Constraints

- Use async/await and actors (no Combine)
- All models must be Sendable
- Use AppLogger for debugging
- Follow existing AgentHub patterns
- Check Context7 for ALL SwiftUI/Swift APIs

## Questions to Resolve

1. Keep terminal as fallback/debug option?
2. How to handle long-running tools (Bash with streaming output)?
3. UI design for tool approval - sheet vs inline?
4. Support for attachments/images in messages?

## Resources

- Claude Code Headless Docs: https://code.claude.com/docs/en/headless
- Conduit CLI Source: https://github.com/conduit-cli/conduit
- Existing AgentHub code in `app/modules/AgentHubCore/`
- Contract template: `.claude/contracts/CONTRACT_TEMPLATE.md`

## Getting Started

1. Read this entire prompt
2. Explore the Conduit CLI source code (clone it locally)
3. Read existing AgentHub services for patterns
4. Create a contract at `.claude/contracts/headless-streaming.md`
5. Implement in patchsets: Models → Service → ViewModel → UI
