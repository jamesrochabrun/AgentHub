# AgentHub Feature Proposals — Lessons from RepoPrompt CE

**Date:** 2026-06-04
**Method:** Multi-agent study of the RepoPrompt CE source tree + all of its documentation (8 subsystem deep-dives) cross-referenced against a map of AgentHub's current capabilities and gaps (6 mapping passes), then synthesized and adversarially re-ranked by direct user benefit. Every cited file path was verified to exist in the respective repo during the study.
**Scope:** Features and improvements for AgentHub (`~/Developer/AgentHub`) borrowing what makes RepoPrompt CE good. Ranked strictly by **impact = concrete, direct benefit to AgentHub's end users** (developers running coding agents).

---

## Executive summary

AgentHub is a strong real-time **cockpit** for coding-agent CLI sessions: it watches Claude Code and Codex live, embeds terminals, reviews libgit2 diffs, observes GitHub PRs/CI, and orchestrates parallel worktree sessions. But it treats the single most important input to any agent — **the context the agent receives** — as opaque free text. Every session and every orchestrated worktree launches with a plain `initialPrompt` string pushed into the terminal (`PendingHubSession.initialPrompt` → `pendingTerminalPrompts`); `OrchestrationSession` carries only a `prompt: String`; remix passes a transcript reference. There is no file selection, no token accounting, no code maps, no slicing, no reusable presets — **exactly the problem RepoPrompt CE was built to solve.**

The highest-leverage move is to add a **Context Builder** layer that turns *"type a prompt and hope the agent finds the right files"* into *"curate a reviewable, token-budgeted context package and hand it to the agent,"* and to make the **apply side** of the review loop resilient.

The top three are the daily-workflow changers:

1. **Context Builder** — curated, token-budgeted context attached to every launch.
2. **RepoPrompt-grade fuzzy diff apply** — fixes the review-and-apply loop, which today silently breaks on whitespace drift in `PendingChangesPreviewService` (verified: it uses naive `range(of:)` / `replacingOccurrences`).
3. **Code Maps** — orient agents on unfamiliar repos at ~10–20× lower token cost.

The mid tier adds token budgeting (merged with the file picker), line-range slicing, reusable context profiles, context-aware orchestration, and an MCP context backend. Long-term covers multi-root workspaces and an AST symbol index that build on code maps. Quick wins (artifact-contamination guard, ignore-rule-aware selection extending AgentHub's existing gitignore handling) ship value in days.

---

## What actually makes RepoPrompt good

RepoPrompt CE's core insight: **context engineering should be a first-class, visible, human-controllable workflow rather than a hidden detail.** Instead of dumping folders at an agent, the user deliberately curates a payload:

- **Select** files, **slice** them to the lines that matter, swap full content for tree-sitter **code maps** (signature-only API surfaces costing ~10–20× fewer tokens).
- Watch a **live per-file and total token count** against a budget.
- **Reorder and toggle** sections (file tree, contents, git diff, instructions).
- **Review the exact bytes** before they reach the model.

Three more things make it good:

1. **Everything is reusable and persistent** — `StoredSelection` and `CopyPreset` capture entire context states as named profiles.
2. **The apply side is resilient** — n-gram + Levenshtein fuzzy search/replace (`DiffGenerationUtility`), escape-sequence fallback and indentation healing (`ApplyEditsEngine`), per-edit batch outcomes, and an artifact-contamination guard, all gated behind a unified-diff approval flow.
3. **Provider-neutral, MCP-exposed** — the whole thing is an MCP server so external agents can query and mutate curated context programmatically.

The throughline: **make what the agent sees explicit, cheap, reviewable, and reusable.**

---

## AgentHub today

AgentHub is a SwiftUI macOS Xcode project (modules under `app/modules`: `AgentHubCore`, `AgentHubCLI`, `AgentHubGitHub`). It is a strong cockpit: kqueue-based session monitoring, provider-agnostic protocols for Claude Code and Codex, embedded terminals, libgit2 diff review, GitHub PR/CI observation, web preview, iOS Simulator integration, worktree management, and Smart-mode orchestration that spawns parallel sessions.

The architecture is clean and ready to host this work:

- `@Observable @MainActor` view models; actor-based services behind protocols (`FileIndexService`, `GitDiffService`).
- GRDB/SQLite persistence (`SessionMetadataStore`); a service-locator DI container (`AgentHubProvider`).
- A Cmd+P file picker (`QuickFilePickerView`); `FileIndexService` already parses and caches `.gitignore`.

**The crucial constraint:** AgentHub drives external CLIs and is **not** the model runtime — it cannot pick or configure a model, only the harness can. So none of these proposals try to change model behavior; they change *what the agent is handed*.

**The core gap:** AgentHub orchestrates and observes agents but does nothing to curate the context they receive.

- Sessions launch with a free-text `initialPrompt` string pushed into the terminal (verified path: `PendingHubSession.initialPrompt` → `pendingTerminalPrompts`).
- `OrchestrationSession` carries only a `prompt: String` (verified — no context payload).
- Remix passes a transcript reference (`forkSession` in `CLISessionsViewModel` ~2593).
- `PendingChangesPreviewService` (189 lines) applies edits with naive `range(of:)` / `replacingOccurrences` and no fuzzy matching (verified).
- The MCP server (`AgentHubMCPServer`, ~851 lines) exposes 4 tools — create/list/delete worktree sessions plus an advisory planning tool — but no context tools.
- Cost/usage tracking exists but is purely historical (parsed from JSONL); there's no forward-looking budget.

**Everything needed to host a Context Builder already exists; the curation layer itself is missing.**

---

## Ranked feature list

| # | Feature | Impact | Effort | Tier |
|---|---------|--------|--------|------|
| 1 | Context Builder: curated, token-budgeted context attached to every launch | **Critical** | L | Core bet |
| 2 | RepoPrompt-grade fuzzy diff apply for the review-and-apply pipeline | **Critical** | M | Core bet |
| 3 | Code Maps: signature-only repo overview (~10–20× lower token cost) | High | XL | Core bet |
| 4 | Token budget meter + pre-launch cost estimate (token-aware file picker) | High | M | Core bet |
| 5 | Semantic line-range slicing in the context picker | High | M | Core bet |
| 6 | Context Profiles: reusable, named context + prompt presets | High | M | Core bet |
| 7 | Context-aware orchestration: per-session curated context in Smart mode | High | L | Core bet |
| 8 | Artifact-contamination guard on agent-applied edits | Medium | S | **Quick win** |
| 9 | Ignore-rule-aware context selection + large-file auto code map | Medium | M | **Quick win** |
| 10 | Remix carries curated slices instead of a raw transcript blob | Medium | M | Long-term |
| 11 | AgentHub MCP context backend: agents query and stage curated context | Medium | L | Long-term |
| 12 | Workspace-scoped multi-root indexing (related repos + docs as one unit) | Medium | L | Long-term |
| 13 | AST symbol index with go-to-definition and symbol search | Low | L | Long-term |

### How these fit together (sequencing)

Most of the value chains off **one foundational piece, #1 the Context Builder.** Build it first; almost everything else slots into its selection model and assembly path.

```
                    ┌─────────────────────────────┐
                    │  #1 Context Builder (L)      │  ← foundation
                    │  selection model + assembly  │
                    └───────────────┬─────────────┘
        ┌───────────────┬───────────┼───────────────┬───────────────┐
        ▼               ▼           ▼                ▼               ▼
  #4 Token meter   #5 Line     #6 Context      #7 Context-aware  #9 Ignore-rule
     (M)              slicing(M)   Profiles (M)    orchestration(L)  selection (M)
        │                                              │
        ▼                                              │
  #3 Code Maps (XL) ──────────────┬────────────────────┘
        │                         ▼
        ▼                  #11 MCP context backend (L)
  #12 Multi-root (L)
  #13 AST symbol index (L)

  Independent track (no Context Builder dependency):
  #2 Fuzzy diff apply (M)  +  #8 Artifact guard (S)   ← rewrite PendingChangesPreviewService together
```

**Recommended order:** ship #2 + #8 first (independent, isolated blast radius, immediate reliability win), then #1, then the #4/#5/#6 trio that ride on it, then #7 and #9, then the code-map-dependent long-term items (#3 → #11/#12/#13).

---

## Detailed proposals

### 1. Context Builder — curated, token-budgeted context attached to every launch
**Impact: Critical · Effort: L · Tier: Core bet · Inspired by: RepoPrompt Context Building (`StoredSelection`, `PromptContextAccountingService`, `PromptAssemblyBuilder`, XML-tagged sections)**

**Why it matters:** The highest-leverage feature — it touches every session AgentHub launches. Today users type free text and hope the agent greps to the right files, burning tokens and time on discovery and often acting on incomplete understanding. A Context Builder lets users deliberately select the exact files and slices an agent starts with, see the token cost, and hand over a focused, reviewable package — improving first-pass accuracy and cutting wasted spend on every launch.

**What to build:** Add a "Curate Context" panel to the new-session flow and `MultiSessionLaunch`. Mirror RepoPrompt's Context Builder: a file tree/grid for multi-select (respecting `.gitignore` via the existing `FileIndexService`), per-file and running-total token estimates, and a live budget bar. Capture selection as a `StoredSelection`-style model (paths + optional line slices + code-map flags) and assemble it with a `PromptAssemblyBuilder` into an XML-tagged block (`<file_map>`, `<file_contents>`, `<user_instructions>`) prepended to the launch prompt. Render the assembled text so the user reviews exactly what the agent will see. Resolve files on a bounded-concurrency actor (RepoPrompt's `PromptContextAccountingService` pattern, ~4 concurrent reads) with content-fingerprint caching so curating dozens of files never blocks `@MainActor` — this plumbing is part of this feature, not a separate item. For very large payloads, write context to a temp file and reference it to respect CLI stdin/prompt limits.

**Where it plugs in:** New `ContextBuilder` service + view in `AgentHubCore`. Plugs into `MultiSessionLaunchViewModel` and `CLISessionsViewModel.startNewSessionInHub`: instead of a bare `initialPrompt` string, assemble the context block and prepend it to the prompt routed through `PendingHubSession.initialPrompt` → `pendingTerminalPrompts`. Reuses `FileIndexService` for the tree and `GitDiffService` for optional diff inclusion.

**Risks:** Token estimate is heuristic, not the provider's true tokenizer, so the budget is approximate (label it "estimated"). Large selections need async parallel reads to avoid UI jank (included above). Injecting a large block into the terminal must respect CLI prompt-size limits — fall back to a temp-file reference for big payloads.

---

### 2. RepoPrompt-grade fuzzy diff apply for the review-and-apply pipeline
**Impact: Critical · Effort: M · Tier: Core bet · Inspired by: RepoPrompt Diffing (`DiffGenerationUtility` n-gram + indent correction, `ApplyEditsEngine` escape fallback and batch outcomes)**

**Why it matters:** Fixes a daily, observable failure with isolated blast radius. `PendingChangesPreviewService` (verified, 189 lines) uses naive `range(of:)` / `replacingOccurrences` and breaks the moment whitespace or indentation drifts — common in model output — silently skipping or hard-failing. n-gram + Levenshtein fuzzy matching with escape-sequence fallback and per-edit outcomes makes previews succeed where they currently fail and shows *"applied 3/4, edit 2 not found"* instead of an opaque failure. Directly improves the trust and reliability of the loop users depend on every day; M effort because the matching utilities are pure functions.

**What to build:** Replace the string-matching internals of `PendingChangesPreviewService` with a port of RepoPrompt's `DiffGenerationUtility.findBestMatchUsingNGrams` (3-gram coarse sweep then refined local-window search with similarity scoring), add an escape-sequence fallback (retry with `\n` / `\t` / `\"` decoded, from `ApplyEditsEngine`), indentation healing to re-indent the replacement to match the matched block, and return per-edit outcomes so MultiEdit shows which edits succeeded. Keep exact-match first so confident edits stay deterministic; surface similarity/confidence and the matched location in the preview so users can confirm a fuzzy hit.

**Where it plugs in:** Rewrite internals of `app/modules/AgentHubCore/Sources/AgentHub/Services/PendingChangesPreviewService.swift`; surface outcomes in `PendingChangesView`. Matching utilities are pure functions, unit-testable and isolated from the libgit2 `GitDiffService`.

**Risks:** Fuzzy matching can match the wrong block when a file has near-duplicate regions; mitigate with a confidence threshold and by showing the matched location for user confirmation. Preserve exact-match-first behavior so deterministic edits stay deterministic.

---

### 3. Code Maps — signature-only repo overview to orient agents at ~10–20× lower token cost
**Impact: High · Effort: XL · Tier: Core bet · Inspired by: RepoPrompt Code Map & Syntax Parsing (`FileAPI`, `CodeMapExtractor`, code-map cache, language strategies)**

**Why it matters:** When an agent starts on an unfamiliar codebase it either reads dozens of full files (huge token burn, slow) or guesses. A tree-sitter code map gives the structural API surface of 100+ files in a few thousand tokens — classes, signatures, types, imports, no bodies. Users orienting a fresh agent get accurate understanding for pennies, and long sessions stay inside the context window far longer. High rather than Critical only because it is XL effort and lands after the Context Builder skeleton exists.

**What to build:** A `CodeMap` service using tree-sitter (Swift, TS/TSX, Python, Go, Rust) that extracts a signatures-only `FileAPI` per file, with content-fingerprint caching (SHA256 + byte count) persisted in SQLite so restarts are instant. Expose a per-file toggle in the Context Builder grid — **full / code map / exclude** — plus an "auto" mode that maps files over ~1000 lines. Pre-compute each map's token cost so the budget bar reflects the cheaper choice. Inject maps as a `<file_map>` referenced-API block. Mirror RepoPrompt's `CodeMapUsage` modes and lazy query compilation at boot.

**Where it plugs in:** New `CodeMap` module in `AgentHubCore`. Feeds the Context Builder grid and the token budget bar. Cache lives in `SessionMetadataStore` via a new GRDB migration. Reuses `FileIndexService` enumeration to discover files to map.

**Risks:** tree-sitter grammars increase binary size and build complexity; per-language `.scm` queries need maintenance as grammars evolve. Parsing very large or odd files can be slow — needs the cache and a size cap. Highest-effort item; ship after the Context Builder skeleton so it slots into existing UI.

---

### 4. Token budget meter and pre-launch cost estimate (with token-aware file picker)
**Impact: High · Effort: M · Tier: Core bet · Inspired by: RepoPrompt `TokenCalculation` + budget-aware packaging with middle-truncation; token-counting integrated into file selection**

**Why it matters:** AgentHub tracks only historical tokens/costs and offers zero forward-looking control; sessions and orchestration plans launch blind to context size or projected cost. A live budget meter while curating, plus an estimated token/cost figure per session before approval, turns an opaque API constraint into a visible control and prevents context-window overflow and runaway spend. Merging the token-aware Cmd+P picker here keeps the estimator single-sourced and high-frequency.

**What to build:** A fast model-agnostic estimator (UTF-8 / 4 × 1.05 with per-model multipliers) and a counting view model that separates files-only, code-map, and git-diff tokens. Surface a budget bar in the Context Builder. In Smart-mode plan review, annotate each session with estimated context tokens and a rough cost using AgentHub's existing per-provider cost data. **Warn (don't silently drop)** when a selection exceeds the model's window, offering middle-truncation of the largest files with a visible marker. Augment `QuickFilePickerView` rows with an estimated token count and a "large — code map suggested" badge, plus an "Add to context" action that pushes the file into the current selection — reusing the same estimator only on visible rows to keep the picker snappy.

**Where it plugs in:** New `TokenCalculation` service in `AgentHubCore`. Drives the Context Builder budget bar, annotates `OrchestrationPlan`/`OrchestrationSession` rows in `MultiSessionLaunchView`'s plan-review section, and feeds `QuickFilePickerView`/`SearchResultRow`. Cost figures reuse the existing JSONL-derived usage/cost data (`GlobalStatsCache`).

**Risks:** Heuristic counts diverge from provider tokenizers (especially code/CJK); label clearly as "estimate." Cost projection depends on knowing the model, which Codex does not always expose pre-launch. Estimating every search result must be lazy/cached.

---

### 5. Semantic line-range slicing in the context picker
**Impact: High · Effort: M · Tier: Core bet · Inspired by: RepoPrompt `LineRange` + `StoredSelection` slices (explicit vs. implicit context)**

**Why it matters:** Agents usually need one function or class out of a 2000-line file, not the whole thing. Drag-selecting line ranges (and tagging why) cuts token burn 5–10× on large files and focuses the agent on the relevant region. It also makes remix and "explain this" workflows precise instead of dumping entire files.

**What to build:** A `LineRange(start, end, description)` model (1-based inclusive). In the Context Builder file preview and the in-app editor (`SourceCodeEditorView`, verified ~610 lines), let users drag-select lines and "Add slice" with an optional one-line reason. Slices feed the assembled block (only those lines, with a header) and the token meter. Visually distinguish full vs. sliced files (e.g., partial = orange) as RepoPrompt does.

**Where it plugs in:** Extends the Context Builder selection model and reuses `SourceCodeEditorView`'s existing selection/line infrastructure. Slices serialize into the same assembled-prompt path (`pendingTerminalPrompts`).

**Risks:** Line ranges go stale if the file changes between selection and launch — resolve slices at assembly time against current content. Drag-select must not conflict with normal editing in the code editor.

---

### 6. Context Profiles — reusable, named context + prompt presets
**Impact: High · Effort: M · Tier: Core bet · Inspired by: RepoPrompt `CopyPreset` / `StoredSelection` / `StoredPrompt` + Prompt Composition presets**

**Why it matters:** Developers repeat task shapes (bug triage, API change, backend test fix) and re-curating files and instructions each time is tedious. Saved profiles ("Backend Tests", "API Changes") let users one-click apply a proven selection + slicing + code-map strategy + instruction template when spinning up any session, making good context the *default* rather than an effort. Also absorbs the prompt-section ordering/toggling concern: section layout is saved per profile rather than being a standalone feature.

**What to build:** Persist named profiles (RepoPrompt `CopyPreset`/`StoredSelection`) capturing selected paths, slices, code-map mode, section ordering/toggles (the PromptAssembly layer), and an attached instruction template. Offer an "Apply context profile" dropdown in the launcher. Include a small stored-prompt library of reusable instruction blocks (`StoredPrompt`) that can be appended as meta-instructions. Profiles persist across sessions and repos; version the schema from day one.

**Where it plugs in:** New tables in `SessionMetadataStore` (append-only GRDB migration). UI in `MultiSessionLaunchView` and the new-session flow. Builds directly on the Context Builder selection model.

**Risks:** Paths in a profile may not exist in a different repo — validate on apply and show which files are missing rather than failing. Schema will evolve; version it from the start.

---

### 7. Context-aware orchestration — per-session curated context in Smart mode
**Impact: High · Effort: L · Tier: Core bet · Inspired by: RepoPrompt per-session curated context handoff + `StoredSelection`**

**Why it matters:** Smart mode's biggest weakness is that parallel sessions launch with text-only prompts (verified: `OrchestrationSession` has only `prompt: String`) and no curated code context — no git diff, no file list, no slices. Attaching a curated package to each session means each parallel agent starts focused on its slice instead of re-discovering the repo three times in parallel, which is what makes multi-session orchestration produce usable results.

**What to build:** Extend `OrchestrationSession` with an optional structured context payload (selected paths, slices, code-map mode, included diff) alongside its prompt. During plan generation or plan review, let the planner or user attach/curate context per session, snapshotting repo state at plan time. At launch, assemble each session's block and prepend it to that session's `initialPrompt`. Show each session's token estimate in review. Default to an "auto" curation so users are never forced to hand-curate N sessions.

**Where it plugs in:** Extend `OrchestrationSession`/`OrchestrationPlan` in `WorktreeOrchestrationTool.swift`; wire through `MultiSessionLaunchViewModel.launchOrchestrationSessions` where each `session.prompt` is currently the sole `initialPrompt`. Reuses the Context Builder assembly path.

**Risks:** Depends on the Context Builder existing first (code maps optional). Per-session curation adds steps to smart launch — keep an "auto" default.

---

### 8. Artifact-contamination guard on agent-applied edits  ⚡ Quick win
**Impact: Medium · Effort: S · Tier: Quick win · Inspired by: RepoPrompt `ApplyEdits` echo/artifact-contamination guard**

**Why it matters:** Models occasionally echo their own tool-call markers (e.g. `to=functions`, repeated apply markers) into replacement text, corrupting files. Hard-rejecting these before writing prevents a class of silent file-corruption bugs with almost no downside — a pure safety win that pairs naturally with the fuzzy-apply rewrite (#2).

**What to build:** Port RepoPrompt's echo-guard reject logic: scan replacement/preview content for known hallucination markers and reject the edit with a clear message and the offending tokens surfaced so the user/agent can regenerate clean code. Run it at the pending-changes preview boundary. Use occurrence thresholds (RepoPrompt's ≥10) rather than any single match to avoid false positives on legitimate tooling source.

**Where it plugs in:** A validation pass inside `PendingChangesPreviewService` before producing `previewContent`; surfaced as a rejection state in `PendingChangesView`. Ships alongside the fuzzy-apply rewrite of the same file.

**Risks:** Very low. Must avoid false positives on code that legitimately mentions these strings — use occurrence thresholds, not single matches.

---

### 9. Ignore-rule-aware context selection + large-file auto code map  ⚡ Quick win
**Impact: Medium · Effort: M · Tier: Quick win · Inspired by: RepoPrompt `IgnoreRules` / hierarchical ignore evaluation + auto-codemap selection**

**Why it matters:** Naive selection sweeps in `node_modules`, build output, lockfiles, and binaries — wasting tokens and degrading agent output. AgentHub's `FileIndexService` already parses `.gitignore` (verified), so this is an incremental extension: add layered ignore sources and auto-route large files to code maps to keep curated context clean and cheap by default. Honest Medium impact since the gitignore baseline already exists.

**What to build:** Extend `FileIndexService`'s existing gitignore handling with priority-ordered layered sources (global defaults + `.gitignore` + `.repo_ignore` + `.cursorignore`) and parent-directory locking for fast early termination, applied to the Context Builder tree and search. Auto-mark files over a configurable size threshold for code-map-only inclusion. Offer "Exclude ignored files" and "Auto code map for large files" toggles, always showing what was excluded with an override.

**Where it plugs in:** Extends `FileIndexService`'s existing gitignore parsing with multi-source priority rules and parent-locking; auto-codemap behavior feeds the CodeMap module's per-file mode (degrades gracefully before code maps ship).

**Risks:** Ignore-rule precedence is subtle (parent vs child, negation) — reuse a well-tested wildmatch approach. Auto-excluding a wanted file is annoying; always show exclusions and allow override.

---

### 10. Remix carries curated slices instead of a raw transcript blob
**Impact: Medium · Effort: M · Tier: Long-term · Inspired by: RepoPrompt reviewable line-sliced context as the default handoff unit; `StoredSelection`**

**Why it matters:** Remix currently passes the previous session's transcript as an inline text reference (verified: `forkSession` → `startNewSessionInHub(initialPrompt:)`) — verbose, token-heavy, noisy. Letting the user curate what carries over (specific files, slices, the relevant diff, a short summary) makes branched sessions start with focused context, so the forked agent picks up the thread without re-reading the whole prior conversation.

**What to build:** When forking, open the Context Builder pre-populated with the source session's touched files (derived from its tool-use history via `SessionJSONLParser`) and offer a curate step: keep relevant slices, include the working diff, add a short carry-over summary instead of the full transcript. Assemble into the new session's `initialPrompt` via the standard context-block path. Let users add/remove files freely so the derived set is a starting point, not a constraint.

**Where it plugs in:** Hooks the existing fork/remix flow in `CLISessionsViewModel` (`forkSession` / `startNewSessionInHub` around lines 2593–2654). Touched-file derivation reuses `SessionJSONLParser` tool-step data.

**Risks:** Depends on the Context Builder. Deriving "touched files" from transcript tool calls is approximate; treat it as a starting point users can edit.

---

### 11. AgentHub MCP context backend — let agents query and stage curated context
**Impact: Medium · Effort: L · Tier: Long-term · Inspired by: RepoPrompt MCP Server (tool groups, selection tools, code-structure, `resolve_referenced_files`, `context_builder`)**

**Why it matters:** AgentHub's MCP server (verified ~851 lines) exposes only 4 tools — create/list/delete worktree sessions plus an advisory planning tool — so a running agent cannot ask AgentHub for curated context or stage a file selection. Exposing context tools (token-aware selection, code symbols, code maps, referenced-file resolution) lets an agent build the right file set inside AgentHub and reason about edit scope instead of blindly grepping, improving accuracy without the user babysitting. Medium rather than High because it benefits agents indirectly and requires cross-process state sharing.

**What to build:** Add MCP tools to `AgentHubMCPServer` modeled on RepoPrompt's grouped catalog: `manage_selection` (get/add/remove/set; modes full/slices/codemap_only) over a shared workspace selection; `get_code_symbols(file)` returning the `FileAPI`; `resolve_referenced_files(selected)` via transitive type-reference discovery; and a token-budgeted `context_builder` tool. Group tools (context/explore/edit) so callers request only relevant subsets. Version the tool schema.

**Where it plugs in:** Extend `AgentHubMCPServer.swift` (currently 4 tools) and `AgentHubCLI`. Selection state and code maps reuse the Context Builder + CodeMap services. The MCP server runs as a separate CLI process, so sharing live selection/codemap state needs an IPC channel — extend the existing `~/.agenthub` file-queue bridge or add a socket.

**Risks:** Cross-process state sharing between the CLI MCP server and the app is the main cost; reuse the existing file-queue IPC or add a socket. Tool schema must stay stable for agents; version it. Depends on Context Builder + code maps for full value.

---

### 12. Workspace-scoped multi-root indexing — related repos + docs as one unit
**Impact: Medium · Effort: L · Tier: Long-term · Inspired by: RepoPrompt multi-root workspaces (`WorkspaceLookupRootScope`, alias-prefixed paths)**

**Why it matters:** Real work spans microservices, shared packages, and docs, but AgentHub's picker and search are single-project today, so users curating context for a cross-repo task cannot pull in a sibling package or docs folder. Multi-root workspaces let selection and search span the whole logical project and surface cross-root references agents otherwise miss. Long-term because it touches single-project assumptions baked across many views.

**What to build:** Introduce a workspace abstraction holding multiple roots (RepoPrompt multi-root `WorkspaceContext`) with alias-prefixed paths to disambiguate (`api/src/x.ts` vs `web/src/x.ts`) and a scope enum (visible / all / session-bound). The Context Builder, Cmd+P picker, and global search operate across roots; index each root once and serve slices to multiple sessions.

**Where it plugs in:** Extends `FileIndexService` and the file/session search services to accept multiple roots; persists workspace root sets in `SessionMetadataStore`. Feeds the Context Builder and `QuickFilePickerView`.

**Risks:** Touches the single-project assumption baked into many views and the session-to-repo grouping logic; needs careful migration. Path-disambiguation UI can confuse users if aliases are not obvious.

---

### 13. AST symbol index — go-to-definition and symbol search
**Impact: Low · Effort: L · Tier: Long-term · Inspired by: RepoPrompt `ReferencedTypesAccumulator` + code-map capture index + warm syntax cache**

**Why it matters:** AgentHub's search is filename/path + content only, with no symbol awareness. A cached symbol index (a byproduct of code maps) enables symbol search by name, go-to-definition in the built-in editor, and auto-pulling the files that define types used by selected files. Genuinely useful but Low/Long-term: it strictly depends on code maps shipping first and is heuristic for dynamically typed languages, so it serves a narrower slice of daily work than the items above.

**What to build:** A workspace symbol database on the CodeMap `FileAPI` cache: `search_symbols(name)` returning `(file, symbol)`, and a transitive `resolve_referenced_files` that auto-includes files defining referenced types (RepoPrompt `ReferencedTypesAccumulator`). Use a fast capture-index lookup for scope/containment queries powering go-to-definition in `SourceCodeEditorView`.

**Where it plugs in:** Layers on the CodeMap module's cache; adds a symbol-search backend behind the existing search-service protocol pattern and a go-to-definition action in `SourceCodeEditorView`/`FileExplorerView`.

**Risks:** Depends on code maps shipping first. Cross-file reference resolution is heuristic for dynamically typed languages (Python/JS) and may over- or under-include.

---

## The one-line takeaway

AgentHub already wins at **observing and orchestrating** agents. RepoPrompt wins at **deciding what the agent sees**. Bolt RepoPrompt's context-engineering layer onto AgentHub's cockpit — starting with a reliable apply pipeline (#2/#8) and a Context Builder (#1) — and AgentHub becomes the rare tool that controls both halves of the loop.
