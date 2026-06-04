# AgentHub × RepoPrompt — Implementation Spec

**Date:** 2026-06-04
**Status:** Draft for engineering review
**Companion doc:** [`repoprompt-inspired-features.md`](./repoprompt-inspired-features.md) (the impact-ranked product rationale). This document is the **engineering spec**: concrete code pointers, data models, integration points, and task breakdowns.

> All `path:line` references were verified against the working trees at `~/Developer/repoprompt-ce` (RepoPrompt CE — the **source** of mechanisms to port) and `~/Developer/AgentHub` (the **target**). Line numbers are accurate as of this date; treat them as anchors, not contracts — re-grep the symbol if a file has moved.

---

## How to use this spec

Each phase below has the same shape:

- **Goal** — the user-visible outcome.
- **Port from (RepoPrompt CE)** — exact files/types/algorithms to study and adapt. RepoPrompt CE is **Apache-2.0** licensed (see *Licensing & attribution* below); the recommended path is to **re-implement, don't copy-paste** — its types carry RepoPrompt-specific dependencies (`WorkspaceFileRecord`, MCP `Value`, tree-sitter wrappers). Port the *algorithm and data shape*, not the file.
- **Modify (AgentHub)** — exact files/symbols/lines to change, and new types to add.
- **Tasks** — ordered, reviewable units.
- **Acceptance** — how we know it's done.

**Build order (dependency-driven):** Phase 0 is independent and ships first. Phases 1→2→3 form the Context Builder core. Phase 4 (code maps) is the big rock and unblocks 9b/11/13. Everything else hangs off Phase 1's selection model.

```
Phase 0  Apply hardening (fuzzy + artifact guard)   ── independent, ship first
Phase 1  Context Builder foundation                 ── the spine everything attaches to
   ├─ Phase 2  Token budgeting
   ├─ Phase 3  Line slicing
   ├─ Phase 5  Context Profiles
   ├─ Phase 6  Layered ignore rules
   └─ Phase 7  Context-aware orchestration
Phase 4  Code Maps (tree-sitter)  ── big rock
   ├─ Phase 9  MCP context backend
   ├─ Phase 10 Multi-root workspaces
   └─ Phase 11 AST symbol index
Phase 8  Curated remix  ── needs Phase 1
```

---

## Licensing & attribution

> Not legal advice. This records the engineering-relevant facts; get a maintainer/legal sign-off before shipping ported code.

- **RepoPrompt CE** (`~/Developer/repoprompt-ce`) is licensed under the **Apache License 2.0**. It is **not** authored by the AgentHub owner (copyright sits with the RepoPrompt authors, bundle id `com.pvncher.repoprompt.ce`).
- **AgentHub** is **MIT** (© 2026 James Rochabrun). Apache-2.0 → MIT is a compatible, one-way permissive flow: you may incorporate Apache-2.0 material into an MIT project.

Two cases, by what is actually copied:

1. **Functionality / algorithm / design / data shape (the default for this spec).** Copyright does not protect ideas or algorithms — only their concrete expression. A clean-room re-implementation from this spec carries **no license obligation**. This is the recommended path and keeps AgentHub's own code cleanly MIT. Every phase below is written to enable this: it describes *what the mechanism does*, not RepoPrompt's literal source.
2. **Verbatim / near-verbatim source.** Permitted under Apache-2.0 §4, but it triggers conditions: (a) include the Apache-2.0 license text covering those parts; (b) retain all copyright/attribution notices; (c) mark modified files as changed; (d) reproduce any `NOTICE` attributions. If any verbatim code is introduced, add `ThirdPartyLicenses/RepoPrompt-CE/LICENSE` (the Apache-2.0 text) and a top-level `NOTICE`/`THIRD_PARTY_NOTICES.md` entry attributing RepoPrompt CE, and keep those files under their Apache-2.0 header rather than relicensing them MIT.

**Recommendation:** reimplement from this spec (case 1). Add a short courtesy attribution to RepoPrompt CE in the repo (a `NOTICE` line) even for clean-room work — it costs nothing and documents provenance. Defer the full Apache-2.0 attribution tree until/unless verbatim code lands.

**Phase 4 caveat:** code maps depend on tree-sitter grammars, which carry their own licenses (mostly MIT/Apache-2.0). RepoPrompt CE curates these under `ThirdPartyLicenses/tree-sitter/`; AgentHub must add the equivalent attributions when those grammars are vendored.

---

## Source-of-truth reference map (RepoPrompt CE)

Quick index of every mechanism this spec ports. Paths are under `~/Developer/repoprompt-ce/Sources/`.

| Mechanism | File | Key symbol(s) |
|---|---|---|
| Fuzzy search/replace (n-gram + Levenshtein) | `RepoPrompt/Infrastructure/Diffing/DiffGenerationUtility.swift:498` | `findBestMatchUsingNGrams`, `createNGrams` (~778), `LineData` (:64), Dice thresholds (~1220), `matchSelectorFast` (~1242) |
| Apply engine (modes, escape fallback) | `RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsEngine.swift:16` | `apply(request:to:options:)`, `applySingle` (:89), `applyBatch` (:131) |
| Escape-sequence fallback | `RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsEscapeFallback.swift:3` | `resolveSingle`, `resolveBatch` (decode `\n \t \"`) |
| Per-edit batch outcomes | `RepoPrompt/Infrastructure/Diffing/DiffBatchGenerator.swift:33` | `EditOutcome {index, status, error}` |
| Indentation healing | `RepoPrompt/Infrastructure/Diffing/IndentationCorrectionUtility.swift:80` | `reIndentUsingSearchBlock(...)` |
| Artifact / echo guard | `RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsRequestBuilder.swift:286` | `ApplyEditsEchoGuard.validate`, `hardRejectReasons` (:300), threshold ≥10 (:323) |
| Unified-diff approval flow | `RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsApprovalStore.swift:8` | `PendingApplyEditsReview`, `ApplyEditsReviewDecision`, `requestReview` (:100) |
| Unified-diff render | `RepoPrompt/Infrastructure/Diffing/UnifiedDiffGenerator.swift:63` | `buildFromEditChunks` |
| Selection model | `RepoPrompt/Features/Workspaces/WorkspaceModel.swift:148` | `StoredSelection {selectedPaths, autoCodemapPaths, slices, codemapAutoEnabled}` |
| Line range | `RepoPrompt/Infrastructure/WorkspaceContext/Slices/LineRange.swift:1` | `LineRange {start, end, description}` (1-based inclusive, clamped) |
| Slice extraction | `RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceAssembly.swift:1` | `SliceAssemblyBuilder.build(from:ranges:)`, merges overlaps |
| Token accounting (concurrency) | `RepoPrompt/Features/Prompt/Services/PromptContextAccountingService.swift:76` | actor, read concurrency = 4 (:77), `resolveEntries`, `calculatePromptStats` |
| Token estimator | `RepoPrompt/Infrastructure/WorkspaceContext/TokenAccounting/TokenCalculationService.swift:124` | `estimateTokens` = `utf8/4*1.05` (:130), `middleTruncate` (:140) |
| Resolved entry model | `RepoPrompt/Infrastructure/WorkspaceContext/Models/WorkspaceFileContextModels.swift:292` | `ResolvedPromptFileEntry`, `PromptFileEntryMode {fullFile, sliced, codemap}` |
| Prompt assembly | `RepoPrompt/Features/Prompt/Models/PromptAssemblyBuilder.swift:31` | `PromptAssemblyBuilder {order, disabled, snippets}`, `PromptSection` enum |
| Copy preset | `RepoPrompt/Features/Prompt/Models/Copy/CopyPreset.swift:42` | `CopyPreset`, `GitInclusion` |
| Stored prompt library | `RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:77` + `PromptStorage.swift` | `StoredPrompt {id, title, content, isUserEdited}` |
| Layered ignore rules | `RepoPrompt/Infrastructure/FileSystem/IgnoreRules.swift:5` | `IgnoreRules`, `RulesNode`, `addIgnoreFile(content:priority:directoryPath:)` |
| Gitignore compiler | `RepoPrompt/Infrastructure/FileSystem/GitignoreCompiler.swift:116` | `CompiledIgnoreRules`, `GitPattern`, prefilters; last-match-wins |
| Hierarchical evaluator | `RepoPrompt/Infrastructure/FileSystem/HierarchicalIgnoreEvaluator.swift:5` | parent-dir locking |
| FileAPI (code map model) | `RepoPrompt/Features/CodeMap/Models/FileAPI.swift:53` | `FileAPI {imports, classes, functions, …, apiDescription, apiTokenCount}` |
| Code map extractor | `RepoPrompt/Features/CodeMap/CodeMapExtractor.swift:67` | `buildLocalDefinitionBlockIfNeeded` (:544), `resolveReferencedFilePaths` (:812), `CodeMapUsage {auto,complete,selected,none}` |
| Code map cache | `RepoPrompt/Features/CodeMap/CodeMapCacheManager.swift:53` | `CodeMapContentFingerprint {contentHash(SHA256), byteCount}`, version 6 |
| Referenced-types resolver | `RepoPrompt/Features/CodeMap/ReferencedTypesAccumulator.swift:10` | `insert/finalizeSorted`, language-aware filtering |
| Capture index (O(log n) scope) | `RepoPrompt/Features/CodeMap/CodeMapCaptureIndex.swift:13` | `smallestCapture(named:containing:)` |
| Lazy tree-sitter query store | `RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift:53` | `LanguageType` (14 langs), `LazyCodeMapQueryStore.lookup` |
| Language strategy example | `RepoPrompt/Features/CodeMap/LanguageStrategies/SwiftCodeMapStrategy.swift:13` | `TypeBoundary`, `buildContext` |
| MCP tool groups | `RepoPromptMCP/CommandRunner/ToolGroups.swift:12` | `ToolGroup {context, explore, edit, …}`, `ToolGroupCatalog.mapping` |
| MCP tool names | `RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolNames.swift:4` | `manage_selection`, `get_code_structure`, `context_builder`, … |
| MCP context-builder tool | `RepoPrompt/Infrastructure/MCP/WindowTools/MCPContextBuilderToolProvider.swift:94` | `context_builder` tool shape |
| App↔CLI control messages | `RepoPromptShared/MCP/MCPControlMessages.swift:15` | progress/terminate JSON-RPC notifications |

---

## Target integration reference map (AgentHub)

Quick index of every touch point. Paths under `~/Developer/AgentHub/app/modules/`.

| Area | File | Key symbol(s) / lines |
|---|---|---|
| **Edit preview/apply** | `AgentHubCore/Sources/AgentHub/Services/PendingChangesPreviewService.swift` | `generatePreview` (:71), `PreviewResult` (:18-41), `PreviewError` (:44-64), `applyEditPreview` (:131 — `range(of:)` :152, `replacingOccurrences` :144), `applyMultiEditPreview` (:159 — :179/:181) |
| Pending-changes UI | `AgentHubCore/Sources/AgentHub/UI/PendingChangesView.swift` | `loadPreview` (:321), `acceptChanges` (:311), `rejectChanges` (:316), `diffView` (:225 — uses `PierreDiffView`), `errorView` (:205), `onApprovalResponse` (:20) |
| Tool input model | `AgentHubCore/Sources/AgentHub/Models/SessionMonitorState.swift` | `CodeChangeInput` (:216-249), `ToolType {edit,write,multiEdit}` (:217), `PendingToolUse` (:373) |
| Git diff service | `AgentHubGitDiff/Services/GitDiffService.swift` | `GitDiffServiceProtocol` (:36), `renderPayload` (:386), libgit2 backend |
| Git diff models | `AgentHubGitDiff/Models/GitDiffState.swift` | `GitDiffRenderPayload` (:104), `GitDiffFileEntry` (:143), `DiffMode` (:13) |
| **Session launch** | `AgentHubCore/Sources/AgentHub/ViewModels/CLISessionsViewModel.swift` | `startNewSessionInHub` (:2654), prompt routing (:2662), `pendingTerminalPrompts[...]` (:2678), `forkSession` (:2594), fork reference (:2621) |
| Pending session model | `AgentHubCore/Sources/AgentHub/Models/PendingHubSession.swift` | `PendingHubSession {initialPrompt}` (:12-39) |
| Orchestration model | `AgentHubCore/Sources/AgentHub/Intelligence/WorktreeOrchestrationTool.swift` | `OrchestrationSession {…, prompt: String}` (:26-68, prompt :39), `OrchestrationPlan` (:73) |
| Multi-session launch VM | `AgentHubCore/Sources/AgentHub/ViewModels/MultiSessionLaunchViewModel.swift` | `forkInitialPrompt` (:430), `launchOrchestrationSessions` (:752, injection at :791) |
| Plan-review UI | `AgentHubCore/Sources/AgentHub/UI/MultiSessionLaunchView.swift` | `smartPlanReviewSection` (:1323), `SmartPlanDetailView` (:1565), `sessionRow` (:1664-1711) |
| Transcript parser | `AgentHubCore/Sources/AgentHub/Services/SessionJSONLParser.swift` | `parseSessionFile` (:113), `extractCodeChangeInput` (:410), `ParseResult` (:75) |
| **File index / ignore** | `AgentHubCore/Sources/AgentHub/Services/FileIndexService.swift` | actor (:251), `rootNodes` (:393), `children` (:398), `search` (:425), `readFile` (:526), `writeFile` (:548), `parseGitignore` (:988), `IgnoreRule` (:284), `globMatch` (:1083), `ignoreRules(forDirectoryAt:)` (:793), `ProjectFileEnumerating` (:68) |
| **Persistence** | `AgentHubCore/Sources/AgentHub/Services/SessionMetadataStore.swift` | actor (:13), `migrator` (:75), `MigrationID` (:17), migrations v1–v10 |
| **DI container** | `AgentHubCore/Sources/AgentHub/Configuration/AgentHubProvider.swift` | class (:36), lazy services, `makeSessionsViewModel` (:355), `init` (:287) |
| Cmd+P picker | `AgentHubCore/Sources/AgentHub/UI/QuickFilePickerView.swift` | view (:88), `QuickFileResultRow` (:521), search `.task` (:267) |
| In-app editor | `AgentHubCore/Sources/AgentHub/UI/SourceCodeEditorView.swift` | view (:56), `textViewDidChangeSelection` (:279), `setCursorPositions` (:437), `scrollToRange` (:468) |
| MCP server | `AgentHubCLI/Sources/AgentHubCLI/AgentHubMCPServer.swift` | struct (:4), `tools/list` (:56), `handleToolCall` (:110), tool schemas (:566+); IPC: writes `WorktreeLaunchRequest` (:33) to `~/.agenthub/cli-requests/{id}.json` |
| Usage/cost data | `AgentHubCore/Sources/AgentHub/Models/GlobalStatsCache.swift` | `GlobalStatsCache` (:6), `ModelUsage {inputTokens, outputTokens, cache*, costUSD}` (:45) |

---

## New module layout

Add one new SwiftPM target inside `AgentHubCore` to keep context-engineering code cohesive and unit-testable without the app:

```
app/modules/AgentHubCore/Sources/
  AgentHubContext/                 ← NEW target
    Selection/
      ContextSelection.swift        (StoredSelection analogue)
      LineRange.swift
      SliceAssembler.swift
    Tokens/
      TokenEstimator.swift          (pure; utf8/4*1.05 + per-model multipliers)
      ContextAccountant.swift       (actor; bounded-concurrency file reads)
    Assembly/
      ContextAssembler.swift        (XML-tagged block builder)
      ContextSection.swift
    Apply/
      FuzzyMatcher.swift            (n-gram + Levenshtein; pure)
      IndentHealer.swift
      EscapeFallback.swift
      ArtifactGuard.swift
      EditApplyResult.swift         (per-edit outcomes)
    Ignore/
      LayeredIgnoreRules.swift
    Profiles/
      ContextProfile.swift
  AgentHubCodeMap/                  ← NEW target (Phase 4)
    FileAPI.swift
    CodeMapExtractor.swift
    CodeMapCache.swift
    LanguageStrategies/...
```

Rationale: `Apply/` is pure functions (matcher, healer, guard) — unit-test them in isolation with fixtures of real model-generated edits. `AgentHubCodeMap` carries the tree-sitter dependency so the rest of the app doesn't pay that build cost until Phase 4. Register both in `AgentHubCore/Package.swift` and re-export what the app needs.

---

# Phase 0 — Apply pipeline hardening (Features #2 + #8)

**Ship first. Independent of everything else. Isolated blast radius.**

### Goal
The pending-changes preview must succeed where it currently fails. Today `PendingChangesPreviewService` applies a model's `Edit`/`Write`/`MultiEdit` by exact string match, so any whitespace/indent drift in the model's `old_string` makes the preview silently wrong or empty. After this phase: exact-match-first, then fuzzy fallback with confidence, escape-sequence retry, indentation healing, per-edit outcomes ("applied 3/4"), and a hard reject for hallucinated tool-call echo.

### Port from (RepoPrompt CE)
- **Fuzzy matcher** — `DiffGenerationUtility.findBestMatchUsingNGrams` (`Infrastructure/Diffing/DiffGenerationUtility.swift:498`). Algorithm: (A) fast consecutive exact match; (B) 3-gram coarse sweep with Jaccard similarity and a stride; (C) refined local-window search scored by per-line Levenshtein. Adaptive Dice threshold keyed on shortest selector-line length (`~1220`): 0.25 for ≤4-char lines up to 0.80 for >40-char anchors. `LineData` (`:64`) is the normalized line representation (raw / cleaned / loose key / strict key) — replicate the normalization (`processLine`, `canonicalKey` ~933).
- **Escape fallback** — `ApplyEditsEscapeFallback.resolveSingle/resolveBatch` (`…/ApplyEdits/ApplyEditsEscapeFallback.swift:3`): if `search` isn't found but contains `\` escapes, decode C-style (`\n \t \r \" \\`) and retry; keep decoded form only if it then matches.
- **Indentation healing** — `IndentationCorrectionUtility.reIndentUsingSearchBlock` (`Infrastructure/Diffing/IndentationCorrectionUtility.swift:80`): unify indent style, absorb leaked leading indent, compute indent deltas between old/search blocks, apply an affine transform (slope ∈ [0.5, 2.0], maxShift 12) to the replacement, revert if alignment worsens.
- **Per-edit outcomes** — `EditOutcome {index, status, error}` (`Infrastructure/Diffing/DiffBatchGenerator.swift:33`); apply edits sequentially, advance a cursor on success, record failure without aborting the batch.
- **Artifact/echo guard** — `ApplyEditsEchoGuard.validate` + `hardRejectReasons` (`…/ApplyEdits/ApplyEditsRequestBuilder.swift:286/300`): reject if replacement contains `to=functions` (any), the literal apply-tool name (any), or `apply_edits`/marker ≥ 10× (`:323`). Adapt the marker set to AgentHub's reality: Claude/Codex tool-call echoes like `"name":"Edit"`, `functions.`, `<|tool|>`, repeated `tool_use`.
- Similarity primitives in RepoPrompt are C bindings (`repo_levenshtein_distance`, `repo_dice_coefficient`). **Re-implement in pure Swift** — a bounded Levenshtein (early-exit at a cap) and bigram Dice are ~40 lines each and avoid pulling RepoPrompt's C target.

### Modify (AgentHub)
1. **New files** in `AgentHubContext/Apply/`:
   - `FuzzyMatcher.swift` — `func bestMatch(of needle: [String], in haystack: [String]) -> FuzzyMatch?` where `FuzzyMatch {lineOffset: Int, confidence: Double}`. Port phases A/B/C above. Pure, no AgentHub deps.
   - `IndentHealer.swift`, `EscapeFallback.swift`, `ArtifactGuard.swift` — pure functions.
   - `EditApplyResult.swift`:
     ```swift
     public struct EditApplyOutcome: Sendable, Equatable {
       public enum Status: Sendable { case exact, fuzzy(confidence: Double), failed(reason: String), rejected(reason: String) }
       public let index: Int
       public let status: Status
       public let matchedLineRange: ClosedRange<Int>?   // for "show me where it matched"
     }
     public struct EditApplyResult: Sendable, Equatable {
       public let previewContent: String
       public let outcomes: [EditApplyOutcome]
       public var appliedCount: Int { outcomes.filter { if case .failed = $0.status { false } else if case .rejected = $0.status { false } else { true } }.count }
     }
     ```
2. **Rewrite the internals** of `PendingChangesPreviewService.swift`:
   - `applyEditPreview` (`:131`): replace the `replacingOccurrences`/`range(of:)` calls (`:144`, `:152`) with: ArtifactGuard → exact match → escape-fallback → fuzzy match (≥ confidence threshold, suggest 0.82) → indent-heal the replacement → splice. Return an `EditApplyOutcome`.
   - `applyMultiEditPreview` (`:159`): run the same per edit, sequentially, against the progressively-updated content; collect `[EditApplyOutcome]`; never abort the whole batch on one failure (`:179`/`:181` are the lines to replace).
   - Extend `PreviewResult` (`:18-41`) with `outcomes: [EditApplyOutcome]` (default empty for `.write`). Keep `PreviewError` (`:44`) for hard failures (file not found / unreadable), but a single edit not matching is now an *outcome*, not a thrown error.
   - Keep `generatePreview` (`:71`) signature stable so callers don't change.
3. **Surface outcomes** in `PendingChangesView.swift`:
   - Add `@State editOutcomes: [EditApplyOutcome]?`, set from `previewResult.outcomes` in `loadPreview` (`:321`).
   - In the header region near `diffView` (`:225`), render a status chip: "Applied 3/4 · 1 fuzzy · 1 rejected". On a fuzzy/rejected row, show the reason and `matchedLineRange` so the user can confirm or regenerate.
   - For `.rejected` (artifact contamination), show a distinct red banner in `errorView` (`:205`) with the offending tokens.

### Tasks
1. Pure `FuzzyMatcher` + bounded `levenshtein`/`dice` helpers + unit tests against a fixture corpus of real Edit `old_string`s with whitespace drift.
2. `EscapeFallback`, `IndentHealer`, `ArtifactGuard` + tests.
3. `EditApplyResult` types.
4. Rewrite `applyEditPreview` / `applyMultiEditPreview`; keep exact-match-first deterministic.
5. `PendingChangesView` outcome chip + rejection banner.
6. Golden tests: feed 20 historical failing previews, assert they now apply with correct content.

### Acceptance
- A model edit whose `old_string` differs only in leading whitespace/indent now previews correctly with `status == .fuzzy`.
- A `MultiEdit` with one bad edit shows "3/4 applied" and the bad edit's reason, not an empty/aborted preview.
- A replacement containing ≥10 `tool_use` echoes is `.rejected` with the offending tokens shown; nothing is written.
- Exact matches still apply with `status == .exact` (no behavior change for clean edits).

---

# Phase 1 — Context Builder foundation (Feature #1)

**The spine. Most later phases attach here.**

### Goal
Before launching a session (new, or via the launcher), the user can open a "Curate Context" panel: pick files from the project tree (gitignore-respecting), see the assembled block that will be prepended to the prompt, and launch. This turns the bare `initialPrompt` string into `assembled-context-block + user-instructions`.

### Port from (RepoPrompt CE)
- **Selection model** — `StoredSelection` (`Features/Workspaces/WorkspaceModel.swift:148`): `{selectedPaths, autoCodemapPaths, slices: [String:[LineRange]], codemapAutoEnabled}`. Codable; persisted with the workspace.
- **Resolved entry** — `ResolvedPromptFileEntry` + `PromptFileEntryMode {fullFile, sliced, codemap}` (`Infrastructure/WorkspaceContext/Models/WorkspaceFileContextModels.swift:292`).
- **Assembly** — `PromptAssemblyBuilder` (`Features/Prompt/Models/PromptAssemblyBuilder.swift:31`): ordered `PromptSection` list (`fileMap, fileContents, gitDiff, metaPrompts, userInstructions`), a `disabled` set, and pre-rendered `snippets` per section. XML tags (`<file_map>`, `<file_contents>`, `<user_instructions>`) live *inside* the snippets, not in the builder.
- **Bounded-concurrency reads** — `PromptContextAccountingService` is an `actor` with read concurrency = 4 (`Features/Prompt/Services/PromptContextAccountingService.swift:76-77`), resolving selection → entries off the main actor.

### Modify (AgentHub)
1. **New types** in `AgentHubContext/Selection/` and `Assembly/`:
   ```swift
   public struct ContextSelection: Codable, Equatable, Sendable {
     public var selectedPaths: [String]           // project-relative
     public var slices: [String: [LineRange]]     // Phase 3 fills this
     public var codeMapPaths: Set<String>         // Phase 4 fills this
     public var includeGitDiff: Bool
   }
   public enum ContextSection: String, CaseIterable, Codable { case fileMap, fileContents, gitDiff, userInstructions }
   ```
2. **New `ContextAssembler`** — given a `ContextSelection`, current file contents (resolved via `FileIndexService.readFile` `:526`), and the user's instruction text, produce the final string:
   ```
   <file_contents>
   File: app/Foo.swift
   ```swift
   …file or slice text…
   ```
   </file_contents>
   <user_instructions>
   …the user's prompt…
   </user_instructions>
   ```
   For oversized payloads, write the block to a temp file (e.g. `~/.agenthub/context/{uuid}.md`) and have the assembled prompt *reference* it (`Read the curated context at <path>`), respecting CLI prompt-size limits.
3. **New `ContextAccountant` actor** — wraps file reads with a 4-wide `TaskGroup` and content-fingerprint caching (key: path + mtime). Returns resolved entries + content so the UI never reads files on `@MainActor`.
4. **New `ContextBuilderViewModel` (`@Observable @MainActor`)** + `ContextBuilderView` (SwiftUI) under `AgentHub/UI/`. Tree comes from `FileIndexService.rootNodes`/`children` (`:393`/`:398`). Multi-select with checkboxes; a live preview pane renders the assembled block.
5. **Register services** in `AgentHubProvider.swift` (`:36`) following the lazy pattern (model it on `monitorService` at `:57`):
   ```swift
   public private(set) lazy var contextAccountant = ContextAccountant(fileIndex: FileIndexService.shared)
   public private(set) lazy var contextAssembler = ContextAssembler()
   ```
6. **Wire into launch** — `CLISessionsViewModel.startNewSessionInHub` (`:2654`). Today (`:2662`) it routes `initialPrompt` straight to `pendingTerminalPrompts` (`:2678`). Add an optional parameter and prepend the assembled block:
   ```swift
   public func startNewSessionInHub(_ worktree: WorktreeBranch,
                                    initialPrompt: String? = nil,
                                    contextBlock: String? = nil,   // NEW
                                    …) {
     let combined = [contextBlock, initialPrompt].compactMap { $0 }.joined(separator: "\n\n")
     let effectivePrompt = combined.isEmpty ? nil : combined
     // …existing routing at :2662 uses effectivePrompt…
   }
   ```
   The new-session entry UI passes `ContextBuilderViewModel.assembledBlock()` as `contextBlock`.

### Tasks
1. `ContextSelection`, `ContextSection`, `LineRange` (stub slices for now).
2. `ContextAccountant` actor + fingerprint cache + tests.
3. `ContextAssembler` + temp-file fallback + tests (golden assembled output).
4. `ContextBuilderView` / `ContextBuilderViewModel`; tree from `FileIndexService`.
5. DI registration in `AgentHubProvider`.
6. `startNewSessionInHub` `contextBlock` param + new-session UI hook.

### Acceptance
- User selects 3 files, sees the exact assembled block in the preview, launches; the agent's first message contains those files' contents under `<file_contents>`.
- Selecting 50 files does not jank the UI (reads are off-main, ≤4 concurrent).
- A >200 KB selection writes a temp file and the prompt references it instead of inlining.

---

# Phase 2 — Token budgeting (Feature #4)

### Goal
A live token meter in the Context Builder (per-file + total) and a pre-launch estimate per session. Warn — never silently drop — when a selection exceeds a model window. Add token counts to the Cmd+P picker rows.

### Port from (RepoPrompt CE)
- `TokenCalculationService.estimateTokens` (`Infrastructure/WorkspaceContext/TokenAccounting/TokenCalculationService.swift:130`): `Int(Double(text.utf8.count)/4.0 * 1.05)`. No per-model variants there; we add a small multiplier table.
- `middleTruncate(text:maxTokens:marker:)` (`:140`) — grapheme-aware head+tail keep with a `[content truncated]` marker; reuse for over-budget files.
- Separate token buckets (files-only / code-map / git-diff) — `PromptContextAccountingService` keeps these distinct; mirror that so the meter can break down the total.

### Modify (AgentHub)
1. **New `TokenEstimator`** (pure) in `AgentHubContext/Tokens/`:
   ```swift
   public enum TokenEstimator {
     public static func estimate(_ text: String, model: String? = nil) -> Int {
       let base = Int(Double(text.utf8.count) / 4.0 * 1.05)
       return Int(Double(base) * multiplier(for: model))   // 1.0 default; tune per model
     }
     public static func middleTruncate(_ text: String, maxTokens: Int) -> String { … }
   }
   ```
2. **Meter in `ContextBuilderView`** — `ContextBuilderViewModel` exposes `totalTokens`, `perFileTokens: [String:Int]`, and a budget bar; recompute via `ContextAccountant` (cache the per-file counts alongside content).
3. **Pre-launch annotation** — in `MultiSessionLaunchView.SmartPlanDetailView.sessionRow` (`:1664-1711`), add an estimated-tokens badge between branch name and prompt (insertion ~`:1677`). Cost via `GlobalStatsCache.ModelUsage.costUSD` (`GlobalStatsCache.swift:45`) as a rough per-token rate (`costUSD / totalTokens`).
4. **Picker rows** — `QuickFilePickerView.QuickFileResultRow` (`:521`): add a trailing token-count badge and a "large — code map suggested" hint for big files. Compute lazily, only for visible rows, in the existing `.task` (`:267`); cache by path.
5. **Over-budget UX** — when total > model window, show a warning with a one-click "middle-truncate largest files" action (visible marker in the assembled block), not silent dropping.

### Acceptance
- Meter updates within ~100ms of toggling a file; total = Σ per-file + diff bucket.
- Plan-review rows show estimated tokens (and rough $ when model known).
- Over-window selection warns and offers truncation; truncated files show the marker.
- All estimates are labeled "≈ estimate".

---

# Phase 3 — Line-range slicing (Feature #5)

### Goal
In the Context Builder preview and the in-app editor, drag-select line ranges and "Add slice" (optional one-line reason). Only those lines enter the assembled block; the meter reflects the saving. Full vs. sliced files are visually distinct.

### Port from (RepoPrompt CE)
- `LineRange` (`Infrastructure/WorkspaceContext/Slices/LineRange.swift:1`): `{start, end, description?}`, 1-based inclusive, clamped at init.
- `SliceAssemblyBuilder.build(from:ranges:)` (`Infrastructure/WorkspaceContext/Slices/SliceAssembly.swift:1`): normalizes, sorts, **merges adjacent/overlapping** ranges (merge when `range.start <= last.end + 1`), extracts text preserving line endings, returns segments + combined text. **Resolve slices against current content at assembly time** (RepoPrompt does this — a stale range must clamp to current bounds, never crash).

### Modify (AgentHub)
1. Implement `LineRange` + `SliceAssembler` in `AgentHubContext/Selection/`.
2. `ContextSelection.slices` (already declared in Phase 1) now carries data; `ContextAssembler` calls `SliceAssembler` per sliced file and emits a header (`File: app/Foo.swift (lines 40–88: "auth flow")`).
3. **Editor hook** — `SourceCodeEditorView.textViewDidChangeSelection` (`:279`) gives `newPositions`/`NSRange`. Add a callback `onAddSlice: (LineRange) -> Void` and a context-menu / keyboard action that converts the current selection's `NSRange` to 1-based line numbers and appends a slice. Use `scrollToRange` (`:468`) when navigating to an existing slice.
4. Visual: sliced files render with a partial-inclusion indicator (RepoPrompt uses orange) in the tree and preview.

### Acceptance
- Selecting lines 40–88 of a 2000-line file and "Add slice" makes the assembled block contain only those lines under a labeled header; meter drops accordingly.
- Overlapping slices merge. A slice whose end now exceeds the (edited) file clamps instead of crashing.

---

# Phase 4 — Code Maps (Feature #3) — big rock

### Goal
A signature-only structural view of files (classes, funcs, types, imports — no bodies) at ~10–20× lower token cost, toggled per file in the Context Builder (full / code map / exclude), with an "auto" mode for large files. Cached so restarts are instant.

### Port from (RepoPrompt CE)
- `FileAPI` (`Features/CodeMap/Models/FileAPI.swift:53`): the per-file API model with `apiDescription` and `apiTokenCount`.
- `CodeMapExtractor` (`Features/CodeMap/CodeMapExtractor.swift:67`): `buildLocalDefinitionBlockIfNeeded(codeMapUsage:selectedFiles:allFileAPIs:…)` (`:544`) builds the `<file_map>` block with token-budget limiting; `CodeMapUsage {auto, complete, selected, none}`.
- `CodeMapCacheManager` (`Features/CodeMap/CodeMapCacheManager.swift:53`): `CodeMapContentFingerprint {contentHash(SHA256), byteCount}`, cache version (6), JSON on disk, dirty-root tracking, version-mismatch purge.
- `SyntaxManager` lazy query store (`Infrastructure/SyntaxParsing/SyntaxManager.swift:53`): `LanguageType` (14 langs); per-language tree-sitter queries compiled lazily on first use (not at boot).
- `CodeMapCaptureIndex` (`Features/CodeMap/CodeMapCaptureIndex.swift:13`) + a language strategy like `SwiftCodeMapStrategy` (`…/LanguageStrategies/SwiftCodeMapStrategy.swift:13`) for O(log n) scope/containment from tree-sitter captures.

### Modify (AgentHub)
1. **New target `AgentHubCodeMap`** (carries tree-sitter): add tree-sitter + grammars (Swift, TS/TSX, Python, Go, Rust to start) via SwiftPM. Port `FileAPI`, `CodeMapExtractor`, a `CaptureIndex`, and per-language strategies. Keep `.scm` queries as resources.
2. **Cache in SQLite** — add migration `v11_create_codemap_cache` in `SessionMetadataStore.swift` (follow the `MigrationID` pattern at `:17` and the registration block at `:75`; model indexing on `v7_create_managed_processes`). Columns: `rootPath`, `relativePath`, `contentHash`, `byteCount`, `fileAPIJson`, `apiTokenCount`, `updatedAt`. Read-through cache: recompute only when `contentHash` changes.
3. **Per-file toggle** in `ContextBuilderView`: full / code map / exclude. `ContextSelection.codeMapPaths` carries the choice; `ContextAssembler` emits `<file_map>` for those.
4. **Auto mode** + budget: files over a configurable line/byte threshold default to code-map; the Phase 2 meter uses `apiTokenCount` for mapped files.
5. Discovery reuses `FileIndexService` enumeration (`:393`/`:398`).

### Acceptance
- A 1500-line Swift file added as "code map" contributes its signatures (no bodies) and ~10× fewer tokens than full.
- Second launch reads the map from SQLite without re-parsing (verify via timing log).
- Unsupported languages degrade gracefully to full/exclude (no crash).

> This is the XL item. Suggest a vertical slice first: Swift-only extractor + cache + toggle, then add languages.

---

# Phase 5 — Context Profiles (Feature #6)

### Goal
Save a curated selection + slicing + code-map strategy + section layout + an instruction template as a named profile ("Backend Tests", "API Change") and one-click apply it in any session/launcher.

### Port from (RepoPrompt CE)
- `CopyPreset` (`Features/Prompt/Models/Copy/CopyPreset.swift:42`): inclusion flags + content-shaping (`fileTreeMode`, `codeMapUsage`, `GitInclusion`) + `storedPromptIds`.
- `StoredPrompt` + `PromptStorage` (`Features/Prompt/ViewModels/PromptViewModel.swift:77`, `PromptStorage.swift`): a small reusable instruction-block library persisted as JSON with atomic writes and (title, content) de-dup on import.

### Modify (AgentHub)
1. **New `ContextProfile`** (Codable, **versioned** `schemaVersion`):
   ```swift
   public struct ContextProfile: Codable, Identifiable, Sendable {
     public let id: UUID
     public var name: String
     public var selection: ContextSelection
     public var sectionOrder: [ContextSection]
     public var disabledSections: Set<ContextSection>
     public var instructionTemplate: String?
     public var schemaVersion: Int
   }
   ```
2. **Persist** via new migration `v12_create_context_profiles` in `SessionMetadataStore.swift` (+ read/write APIs `saveContextProfile` / `listContextProfiles` following the `getMetadata`/`setCustomName` pattern at `:200`/`:211`).
3. **Apply UX** — "Apply context profile" dropdown in `MultiSessionLaunchView` and the new-session flow. On apply, **validate paths** against the current repo and show which are missing (don't fail) — profiles roam across repos.
4. Optional stored-prompt library (port `StoredPrompt`) for reusable instruction blocks appended as meta-instructions.

### Acceptance
- Save a profile from a curated selection; reopen the app; apply it; selection + slices + code-map modes + instruction template are restored.
- Applying a profile in a different repo flags missing paths but still applies the rest.

---

# Phase 6 — Layered ignore rules (Feature #9) ⚡ quick win

### Goal
Context selection and search honor layered ignore sources (defaults + `.gitignore` + `.agentignore` + `.cursorignore`) with correct precedence, and large files auto-route to code maps.

### Port from (RepoPrompt CE)
- `IgnoreRules` + `RulesNode` linked-list with priority (`Infrastructure/FileSystem/IgnoreRules.swift:5`); `addIgnoreFile(content:priority:directoryPath:)` (`:70`); built-in defaults (`.git`, `.DS_Store`, …).
- `GitignoreCompiler` / `CompiledIgnoreRules` (`Infrastructure/FileSystem/GitignoreCompiler.swift:116`): compiled `GitPattern`s with prefilters, **last-match-wins**, negation support.
- `HierarchicalIgnoreEvaluator` (`…/HierarchicalIgnoreEvaluator.swift:5`): per-component evaluation with **parent-directory locking** for early termination.

### Modify (AgentHub)
- AgentHub already parses `.gitignore` in `FileIndexService` — `parseGitignore` (`:988`), `IgnoreRule` (`:284`), `matchesRule` (`:1045`), `globMatch` with `NSCache` regex (`:1083`), nested collection in `ignoreRules(forDirectoryAt:)` (`:793`). This is an **extension, not a rewrite**:
  1. Generalize `IgnoreRule` parsing to accept a `source`/`priority` and read multiple files per directory (`.gitignore`, `.agentignore`, `.cursorignore`) plus a global default set.
  2. Apply last-match-wins across sources by priority; keep the existing `NSCache` glob path.
  3. Surface "Exclude ignored files" + "Auto code map for large files" toggles in `ContextBuilderView`; always show what was excluded with an override.

### Acceptance
- `node_modules`, `build/`, lockfiles excluded by default from the tree/search; a `!keep.me` negation re-includes correctly.
- Toggling "show ignored" reveals them; user can still force-add an ignored file.

---

# Phase 7 — Context-aware orchestration (Feature #7)

### Goal
Smart-mode parallel sessions each launch with their own curated context (files/slices/diff), not just a text prompt.

### Port from (RepoPrompt CE)
- The per-session curated-context handoff concept + `StoredSelection` as the unit attached to each launch.

### Modify (AgentHub)
1. **Extend `OrchestrationSession`** (`Intelligence/WorktreeOrchestrationTool.swift:26-68`, currently only `prompt: String` at `:39`) with an optional payload:
   ```swift
   public var contextSelection: ContextSelection?   // NEW, Codable
   ```
2. **Assemble at launch** — `MultiSessionLaunchViewModel.launchOrchestrationSessions` (`:752`) passes `session.prompt` as the sole `initialPrompt` at `:791`. Change to assemble each session's `contextSelection` via `ContextAssembler` and pass it as the new `contextBlock` param from Phase 1.
3. **Curate in plan review** — `SmartPlanDetailView.sessionRow` (`:1664`): allow attach/curate per session, defaulting to an **auto** curation (e.g., touched files inferred from the plan) so users aren't forced to hand-curate N sessions. Show each session's token estimate (Phase 2).
4. Snapshot repo state at plan time so a later edit doesn't change what a session receives.

### Acceptance
- A 3-session Smart plan launches three agents, each receiving a distinct curated block; plan review shows three token estimates.
- With no manual curation, "auto" still attaches a sensible default selection.

---

# Phase 8 — Curated remix (Feature #10)

### Goal
Forking a session carries a curated set (touched files, slices, working diff, short summary) instead of a raw transcript reference.

### Modify (AgentHub)
1. **Touched-file derivation** — `SessionJSONLParser.parseSessionFile` (`:113`) + `extractCodeChangeInput` (`:410`) yield the `filePath`s the source session edited (via `ParseResult.recentActivities[].toolInput`). Build a helper that returns the deduped set.
2. **Fork flow** — `CLISessionsViewModel.forkSession` (`:2594`); today it builds `reference` from `MultiSessionLaunchViewModel.forkInitialPrompt` (`:430`) at `:2621`. Instead: open the Context Builder pre-populated with the derived touched files (user can edit), optionally include the working diff (via `GitDiffService.renderPayload` `:386`) and a short carry-over summary, then pass the assembled block as `contextBlock` to `startNewSessionInHub`.
3. Keep "read full transcript at <path>" as an optional appended line, not the primary payload.

### Acceptance
- Remixing a session opens the builder seeded with the files that session edited; the forked agent starts with those files + diff, not a transcript dump.

---

# Phase 9 — MCP context backend (Feature #11)

### Goal
The MCP server exposes context tools so a running agent can query/stage curated context (selection, code symbols, code maps, referenced-file resolution) instead of blind grepping.

### Port from (RepoPrompt CE)
- Tool catalog + grouping — `ToolGroups.swift:12` (`context/explore/edit`), `MCPWindowToolNames.swift:4` (`manage_selection`, `get_code_structure`, `context_builder`, …), the `Tool` base (`Infrastructure/MCP/Tool.swift:13`), and `MCPContextBuilderToolProvider` (`:94`) for the `context_builder` tool shape (instructions → token-budgeted file set).
- `ReferencedTypesAccumulator` (`Features/CodeMap/ReferencedTypesAccumulator.swift:10`) for `resolve_referenced_files`.
- App↔CLI progress/terminate notifications — `MCPControlMessages.swift:15`.

### Modify (AgentHub)
1. **New tools** in `AgentHubMCPServer.swift` (currently 4 tools; `tools/list` at `:56`, dispatch at `:110`, schema fns at `:566+`): `agenthub_manage_selection` (get/add/remove/set; modes full/slices/codemap), `agenthub_get_code_symbols(file)` (returns `FileAPI` from Phase 4), `agenthub_resolve_referenced_files(paths)`, `agenthub_build_context(instructions, budget)`. Follow the existing schema-fn + `handleToolCall` switch pattern.
2. **Cross-process state** — the MCP server is a separate CLI process. Share live selection/code-map state by extending the existing file-queue IPC (the server already writes `WorktreeLaunchRequest` to `~/.agenthub/cli-requests/` — `AgentHubMCPServer.swift:33`) with a `context-requests/` channel, or add a local socket. **Version the tool schema** from day one.

### Acceptance
- From a Claude/Codex session, `agenthub_build_context` returns a token-budgeted file set; `agenthub_get_code_symbols` returns a file's signature surface.
- Tools are grouped so a caller can request only `context`.

---

# Phase 10 — Multi-root workspaces (Feature #12)

### Goal
Selection and search span multiple roots (sibling packages, docs) as one logical project, with alias-prefixed paths.

### Port from (RepoPrompt CE)
- Multi-root `WorkspaceContext` with `WorkspaceLookupRootScope` and alias-prefixed paths (`api/src/x.ts` vs `web/src/x.ts`).

### Modify (AgentHub)
- Generalize `FileIndexService` (`:251`, single `projectPath` today) and the file/session search to accept an ordered set of roots with aliases; persist root sets via a new `SessionMetadataStore` migration. Feed `ContextBuilderView` and `QuickFilePickerView`. This touches the single-project assumption in many views — sequence carefully, behind a flag.

### Acceptance
- A workspace with two roots shows both in the tree/search; selecting files from each produces alias-prefixed headers in the assembled block.

---

# Phase 11 — AST symbol index (Feature #13)

### Goal
Symbol search by name, go-to-definition in the editor, and auto-include of files defining referenced types — all built on the Phase 4 code-map cache.

### Port from (RepoPrompt CE)
- `ReferencedTypesAccumulator` (`:10`) + `CodeMapCaptureIndex.smallestCapture(named:containing:)` (`CodeMapCaptureIndex.swift:13`) for scope/containment.

### Modify (AgentHub)
- Build a workspace symbol DB over the `AgentHubCodeMap` `FileAPI` cache: `searchSymbols(name) -> [(file, symbol)]`, `resolveReferencedFiles(selected)`. Add a symbol-search backend behind the existing search-service protocol and a go-to-definition action in `SourceCodeEditorView` (`:56`) using `setCursorPositions(scrollToVisible:)` (`:437`).

### Acceptance
- Symbol search jumps to a type's definition; selecting a file can auto-pull the files defining the types it references.

---

## Appendix A — GRDB migration template

Follow `SessionMetadataStore.swift` (`MigrationID` at `:17`, `migrator` at `:75`). Migrations are **append-only and ordered** — never edit a shipped migration.

```swift
// 1. add to MigrationID
static let createContextProfiles = "v12_create_context_profiles"
// 2. append to migrationIdentifiers array (:30)
// 3. register
migrator.registerMigration(MigrationID.createContextProfiles) { db in
  try db.create(table: "context_profiles") { t in
    t.column("id", .text).primaryKey()
    t.column("name", .text).notNull()
    t.column("json", .text).notNull()        // encoded ContextProfile
    t.column("schemaVersion", .integer).notNull()
    t.column("updatedAt", .datetime).notNull()
  }
}
// 4. read/write via dbQueue.read/write { db in … } (model on getMetadata :266 / setCustomName :211)
```

## Appendix B — DI registration template

Follow `AgentHubProvider.swift` (lazy services, e.g. `monitorService` at `:57`; `init` at `:287`):

```swift
public private(set) lazy var contextAccountant = ContextAccountant(fileIndex: FileIndexService.shared)
public private(set) lazy var contextAssembler  = ContextAssembler()
public private(set) lazy var codeMapService    = CodeMapService(metadataStore: metadataStore)  // Phase 4
```
Inject into view models the way `makeSessionsViewModel` (`:355`) wires per-provider dependencies.

## Appendix C — Estimated sizing

| Phase | Feature | Effort | Notes |
|---|---|---|---|
| 0 | Apply hardening | M | Pure functions; high test ROI; ship first |
| 1 | Context Builder | L | New target + UI + launch wiring |
| 2 | Token budgeting | M | Pure estimator + meter + plan annotations |
| 3 | Line slicing | M | Editor selection hook + slice assembler |
| 4 | Code maps | XL | tree-sitter target + SQLite cache; slice by language |
| 5 | Context profiles | M | Migration + apply/validate UX |
| 6 | Layered ignore | M | Extends existing FileIndexService parsing |
| 7 | Context-aware orchestration | L | Extends OrchestrationSession + launch |
| 8 | Curated remix | M | Touched-file derivation + builder seeding |
| 9 | MCP context backend | L | New tools + cross-process state |
| 10 | Multi-root workspaces | L | Touches single-project assumptions |
| 11 | AST symbol index | L | Builds on Phase 4 cache |

## Appendix D — Cross-cutting risks

- **Token estimates are heuristic**, not the provider tokenizer — always label "≈". Budgets are guidance, not guarantees.
- **CLI prompt-size limits** — large assembled blocks must fall back to a temp-file reference (Phase 1).
- **Fuzzy matching can mis-match** near-duplicate regions — keep exact-match-first, gate fuzzy on a confidence threshold, and always show the matched location for confirmation (Phase 0).
- **tree-sitter** increases binary size and build complexity, and `.scm` queries need upkeep — isolate in its own target and ship language-by-language (Phase 4).
- **Schema evolution** — version `ContextProfile` and the MCP tool schema from the first commit.
- **AgentHub is not the model runtime** — none of this changes model behavior; it only changes what the agent is handed and how its edits are previewed.
