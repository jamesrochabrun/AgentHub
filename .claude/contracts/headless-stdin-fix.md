# Contract: Headless Mode Stdin Blocking Fix

**ID**: HSF-001
**Created**: 2026-01-24
**Status**: COMPLETE
**Owner**: feature-owner

---

## Problem Statement

Headless mode hangs indefinitely when spawning the Claude CLI process because using a `Pipe()` for stdin causes the CLI to block waiting for input, even though the initial prompt is provided via the `-p` flag.

**Root Cause**: The Claude CLI detects that stdin is a pipe and waits for additional input before processing. This is documented behavior per GitHub issues [#7497](https://github.com/anthropics/claude-code/issues/7497) and [#3187](https://github.com/anthropics/claude-code/issues/3187).

**Evidence from investigation**:
- CLI works perfectly: `/opt/homebrew/bin/claude -p "hi" --output-format stream-json --verbose` returns output immediately
- Swift Process with Pipe for stdin: **HANGS** (no output received)
- Swift Process with `FileHandle.nullDevice` for stdin: **WORKS**

**User Impact**: Headless mode is completely unusable - users see only a spinner with no Claude response.

---

## Acceptance Criteria

| # | Criterion | Verified |
|---|-----------|----------|
| AC1 | Headless mode displays Claude's streaming JSONL output (no longer hangs) | [x] |
| AC2 | Build succeeds with no new warnings | [x] |
| AC3 | Basic prompts complete successfully without hanging | [x] |

---

## Scope

### In Scope
- Fix stdin blocking by using `FileHandle.nullDevice` instead of `Pipe()`
- Remove `--permission-prompt-tool stdio` flag (no longer possible without stdin)
- Add `--permission-mode acceptEdits` flag for auto-accepting edits
- Update `sendControlResponse()` to throw "not supported" error
- Add new error case `toolApprovalNotSupported`
- Remove dead code (`stdinPipe` variable and references)

### Out of Scope
- Full PTY-based interactive tool approval (future enhancement)
- Changes to UI components
- Changes to event parsing logic
- Session resume functionality (unaffected)

---

## Technical Design

### Files to Modify

| File | Changes |
|------|---------|
| `app/modules/AgentHubCore/Sources/AgentHub/Services/ClaudeHeadlessService.swift` | Fix stdin handling, update CLI arguments, update error handling |

### Key Changes

**1. Error Type Addition**
Add `toolApprovalNotSupported` case to `ClaudeHeadlessError`

**2. Actor State**
Remove `stdinPipe: Pipe?` property

**3. CLI Arguments**
- Remove: `--permission-prompt-tool stdio`
- Add: `--permission-mode acceptEdits`

**4. Stdin Configuration**
Change: `process.standardInput = FileHandle.nullDevice`

**5. sendControlResponse()**
Throw `toolApprovalNotSupported` error

**6. cleanupProcess()**
Remove `stdinPipe = nil` reference

**7. Remove ControlResponse struct**
Dead code - no longer used

---

## Patchset Protocol

| PS | Gate | Deliverables | Status |
|----|------|--------------|--------|
| 1 | Models compile | New error case added | [ ] |
| 2 | UI wired | N/A - no UI changes | [ ] Skipped |
| 2.5 | Design bar | N/A - no UI changes | [ ] Skipped |
| 3 | Logic complete | Stdin fix, arguments update, dead code removal | [ ] |
| 4 | Polish | Clean build, verify no hanging | [ ] |

### PS1 Checklist
- [ ] `toolApprovalNotSupported` error case added to `ClaudeHeadlessError`
- [ ] Error description implemented
- [ ] Build succeeds

### PS3 Checklist
- [ ] `stdinPipe` property removed from actor state
- [ ] `process.standardInput = FileHandle.nullDevice` implemented
- [ ] `--permission-prompt-tool stdio` removed from arguments
- [ ] `--permission-mode acceptEdits` added to arguments
- [ ] `sendControlResponse()` throws `toolApprovalNotSupported`
- [ ] `ControlResponse` struct removed (dead code)
- [ ] `cleanupProcess()` updated to remove stdinPipe reference
- [ ] Build succeeds

### PS4 Checklist
- [ ] No compiler warnings
- [ ] No debug statements
- [ ] Basic prompt test confirms no hanging
- [ ] JSONL events are received

---

## Context7 Attestation

| Library | Context7 ID | Why Needed |
|---------|-------------|------------|
| Foundation | /apple/foundation | Process, FileHandle.nullDevice, Pipe |
| Swift | /apple/swift | Actor patterns, async/await |

---

## Agent Workflow

```
feature-owner ─── PS1 → PS3 → PS4 (no UI = skip PS2/2.5)
       │
       ▼
integrator ─── Final verification
```

---

## Sign-off

| Role | Signature | Date |
|------|-----------|------|
| feature-owner | [x] PS1, PS3, PS4 complete | 2026-01-24 |
| integrator | [x] VERIFIED | 2026-01-24 |

**Contract Completion**: COMPLETE

---

## Reference

### GitHub Issues
- [#7497](https://github.com/anthropics/claude-code/issues/7497) - Java apps must close stdin OutputStream
- [#3187](https://github.com/anthropics/claude-code/issues/3187) - Input stream JSON hang

### CLI Flags
```bash
claude -p "prompt" --output-format stream-json --verbose --permission-mode acceptEdits
```
