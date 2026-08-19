# AgentHub Studio

AgentHub renders **artifacts an agent generated during a session** — an HTML document, or a set of design variants laid out on an infinite canvas — in a dedicated side panel where the user can point at any element, comment, tweak it, and send that feedback back to the agent. The guiding principle:

> **The agent renders into a scratch surface, never into the project. Everything the user does on that surface becomes a prompt, never a file write.**

This is the "try it before you build it" counterpart to the web preview panel: web preview shows you the real app, Studio shows you things that do not exist in the codebase yet — and must not, until the user says so.

## On the name

`SidePanelContent.artifact` is already taken by the **claude.ai artifact** panel (a WKWebView over a published `claude.ai/public/artifacts/…` page — a *detection* feature, read-only, Claude-only). That feature and this one share a noun and nothing else. To keep them from being confused forever:

- The existing claude.ai case is renamed `.claudeArtifact` (mechanical; the model is already `ClaudeArtifact` and the detector `ClaudeArtifactURLDetector`).
- This feature is **Studio**, with one panel case, `.studio`: the panel lists every artifact and canvas for the project and the item's `kind` decides how it renders.

The four agent-facing tools: `agenthub_artifact`, `agenthub_design`, `agenthub_list_artifacts`, `agenthub_get_artifact`.

## The tools

| | `agenthub_artifact` | `agenthub_design` |
|---|---|---|
| Renders | one self-contained HTML **document**, served verbatim | N **fragments** of one component, side by side |
| Surface | single scrolling page | infinite pan/zoom canvas of artboards |
| For | reports, diagrams, mockups, dashboards, "show me what this would look like" | "render 6 versions of this button" |
| Panel | `.studio` (kind `.document`) | `.studio` (kind `.canvas`) |
| Re-file | same `id` replaces in place, bumps `revision` | same `id` replaces the whole variant set |
| Inputs | `id?`, `title`, `html` | `id?`, `component`, `sourcePath?`, `props?`, `variants[{name, html, css?, notes?, width?, height?}]` |
| Tweaks | page calls `dc_set_props(...)` itself | one shared `props` schema for the whole canvas |

`agenthub_list_artifacts` returns the project's index (see *Discovery*) so an agent refines an existing item instead of filing a near-duplicate. Both filing tools' descriptions instruct: *list first; when refining, pass the existing `id`.*

`sourcePath` on `agenthub_design` is the real component the variants are exploring (e.g. `src/components/Button.tsx`). It is only used by *Promote* (below) so the promotion prompt can name the file; it never causes AgentHub to read or write it.

### Tweaks — one schema per canvas, not per variant

The Tweaks panel from web preview is ported, with one deliberate difference: on a canvas the schema is **shared by every variant**. The point of a canvas is comparing variants under the same knobs — radius 12 across all four buttons — so per-variant tweaks would defeat it, and sharing is also simpler.

- `agenthub_design` accepts `props`: `{ name: { type: slider|color|select|toggle|text, value, label?, min?, max?, step?, unit?, options? } }` (or an ordered array of `{ name, … }`), validated by `StudioTweakPropParser` at the tool boundary (`maxProps` 24, CSS-identifier-safe names, value matches type, select value ∈ options, slider within range).
- Every prop is exposed to every artboard as the CSS custom property `--<name>`; variants write `var(--radius)`. **A declared prop no variant references is a tool error** (`StudioTweakPropParser.unusedProps`): a control that moves nothing is exactly what a user reports as "tweaks don't work". Sliders carry their `unit`; toggles become `1`/`0`; text/select values are also written into elements marked `data-prop="<name>"`, so copy is tweakable without JS.
- The host page renders defaults into a static `<style id="studio-props">` block (so Export / plain browser look right with no JS), then its script re-applies them, installs `dc_on_props_changed`, and hands the schema to the injected `dc_set_props` runtime — which is what the existing `TweaksPanelView` reads. Live changes go through `TweaksBridge.setProp` and every artboard updates at once.
- **Save defaults** never touches the served cache: canvas → the `props` values in the payload are updated; document → the `dc_set_props` call in the stored HTML is spliced with `TweakPropsSourceEditor` (parser-verified, never a full-file rewrite). Both go through `StudioLibrary.store`, so SQLite stays the source of truth and the revision bump reloads the panel.
- **Ideas / Custom / Delete all** do not spawn web preview's headless tweak agent (it edits a file on disk; Studio has no such file). They go to the *session* as re-file prompts (`StudioTweaksPromptBuilder`), same rails as Send; the spinner clears when the artifact's revision advances or after `rerunTimeout`.
- `agenthub_artifact` documents get Tweaks for free by calling `window.dc_set_props(...)` themselves (the tool description says so, and to guard it with `if (window.dc_set_props)` for plain browsers).
- Text/select values in the static style block are CSS-hex-escaped (`}`, `;`, `<`, `>`, …) so an authored value can never end the rule or the `<style>` element; the schema JSON inlined in the host `<script>` escapes `</`.

### Payload limits (`StudioArtifact.Limits`, enforced at the tool boundary)

| Limit | Value | Why |
|---|---|---|
| `maxDocumentBytes` | 1.5 MB | one artifact document |
| `maxVariants` | 12 | more than that is a gallery, not a comparison |
| `maxVariantBytes` | 256 KB | per variant, html + css combined |
| `maxTitleLength` / `maxNameLength` | 120 / 40 | |
| `StudioTweakPropParser.maxProps` | 24 | one shared schema per canvas |
| variant CSS must parse | — | see *CSS scoping*; unparseable CSS is a tool error, not a rendered lie |

Exceeding a limit is a tool-level error the agent can correct. Never truncate silently — a canvas that dropped two variants misrepresents its own coverage.

## User behavior

- A session's monitoring card shows a **Studio** button only after the agent has filed at least one artifact or design (no proactive UI — same rule as the MCP and Measurements buttons).
- Clicking it opens the side panel. A picker switches between filed items when there is more than one.
- The panel serves from `127.0.0.1`, so **Open in browser** works and the page is a real URL, not a `loadHTMLString` blob. A re-file bumps `revision`; an open panel observes it and reloads.
- **Inspect mode** has the same three behaviours as web preview's strip (Context is omitted there too — Studio has no terminal-attachment queue): **Comment** (click an element, type an instruction, ⏎ sends an element-aware prompt), **Crop** (drag a region; ⏎ sends the region, a screenshot, and the elements inside it), and **Edit** (click an element, adjust it with the Canvas design toolbar — text, font, colour, size, spacing, radius, fit/delete). On a **canvas**, edits are the scratchpad's own business: they are **baked into the variant** — the artboard's `innerHTML` (inline styles/text from the toolbar) is serialized into the variant's `html` on a 500 ms debounce, stored quietly (no page reload; the DOM already equals the payload), and **Revert** restores the version the agent last filed. No agent round-trip: nobody cares how a scratch change is implemented, only that the variant the user eventually picks *is* what they see. On a **document**, edits still go to the agent (**Send to Agent** / **Discard**): serializing a whole scripted document would double its generated content on reload.
- On a design canvas, comments, crops, and edits are stamped with the variant they landed on, so the agent is told *which* version the note is about.
- **Implement** is the one step from scratch surface to code, and it is deliberately obvious: a labelled `Implement ▾` menu in the panel header *and* an "Implement" pill on every artboard caption (the pill posts `{type: "implement", variant}` to a native `agentHubStudio` message handler and is hidden in a plain browser/export). Either path flushes pending bakes first, so the prompt carries the *edited* markup. The same choice can be made in conversation — "let's go with the ghost one" — because the agent is told (guidance + skill) to call `agenthub_get_artifact(id, variant)` and implement exactly what it returns.
- **Export…** saves the served HTML file via `NSSavePanel`; **Copy link** copies the localhost URL (tooltip: valid only while AgentHub is running).
- The panel never auto-opens — button-only (`isAutoOpenableContent` returns `false`).
- Artifacts persist across relaunch, scoped to the **project** (same rule and the same `MeasurementProjectScope` rollup as measurements — a design canvas outlives the conversation that produced it, and a worktree's canvases roll up to the parent repo).

## Data flow

```
agent calls agenthub_artifact(title, html)
       or  agenthub_design(component, variants[…])
   │
   ├─ AgentHubMCPServer validates (limits, CSS parses) + enqueues          ①
   │     StudioArtifactQueue (JSON file, atomic write)
   │     ~/Library/Application Support/AgentHub/studio-records/
   │
   ├─ App drains the queue                                                ②
   │     StudioArtifactMonitor (poll) → StudioArtifactHandler
   │     resolves AGENTHUB_SESSION_ID, else process→session mapping
   │
   ├─ App materializes + stores                                           ③
   │     CLISessionsViewModel.storeStudioArtifact() resolves the project
   │       bucket + branch, then StudioLibrary.store() (one instance shared
   │       by the Claude and Codex view models):
   │       in-memory first (button appears immediately)
   │       → StudioDocumentWriter → studio/{project-hash}/{id}/index.html
   │           document: agent HTML written verbatim
   │           canvas:   host page + StudioCSSScoper-scoped artboards
   │       → SessionMetadataStore.saveStudioArtifact (v18 studio_artifacts)
   │       → StudioIndexStore publish (mirrored to worktree alias paths)
   │
   ├─ Static server                                                       ④
   │     StudioStaticServer — in-process NWListener, GET/HEAD only, rooted
   │     at studio/, 127.0.0.1:{ephemeral}, started lazily on first panel
   │     open; item URL is /{project-hash}/{id}/index.html
   │
   └─ Panel renders + feeds back                                          ⑤
         MonitoringCardView gates the button on studioArtifacts(for:)
         → SidePanelContent.studio → StudioSidePanelView
         → StudioPanelState (selection, reload token) + Canvas
           InspectableWebView + webInspectorOverlay (.input mode)
         → StudioFeedbackPromptBuilder / StudioPromotionPromptBuilder
         → sendPromptToActiveTerminal / showTerminalWithPrompt
```

SQLite is the source of truth; the served `index.html` is a cache. `StudioLibrary.servedURL` rewrites a missing document from the payload before handing out a URL, and `StudioStorageReconciler` (run once at launch) drops directories no row vouches for.

### Why an in-process server, not `python3 -m http.server`

`DevServerManager` shells out to python for static project previews, which is right there — the project is the user's and its serving process belongs in `managed_processes`. Studio content is AgentHub's own directory, so a tiny native `NWListener` HTTP/1.1 server (GET/HEAD only, path-traversal guarded, `Content-Type` by extension, `Cache-Control: no-store`) is the smaller thing: no child process to track and reap, no python dependency, no port-parsing readiness heuristics, and re-file reload is free because nothing is cached. It binds `127.0.0.1` only and starts lazily on first panel open.

## The canvas host page

Artboards are **sibling `<section>` elements inside one document**, not iframes. This is forced by `ElementInspectorBridge.userScript`, which WKWebView injects with `forMainFrameOnly: true` — inside an iframe there is no hover highlight, no click-to-comment, and no element context, which is the entire point of the panel.

```html
<div id="studio-canvas" style="transform: translate(Xpx, Ypx) scale(Z)">
  <figure class="studio-frame" data-variant="primary">
    <figcaption>primary</figcaption>
    <section class="studio-artboard" data-variant="primary">…</section>
  </figure>
  <figure class="studio-frame" data-variant="ghost">…</figure>
</div>
```

- Pan/zoom is a CSS transform on `#studio-canvas`, driven by wheel/trackpad handlers in the host page. The inspector reads `getBoundingClientRect()`, which already accounts for ancestor transforms, so highlight rects stay correct at any zoom — but a transform never fires `scroll`, which is what the inspector bridge listens to for re-posting the selected rect. The host page dispatches a synthetic window `scroll` after every pan/zoom (and after a tweak resizes elements), so the highlight and the native comment box follow the element instead of staying behind.
- The host page carries `<meta name="agenthub-studio-host" content="N">` (`StudioDocumentWriter.hostVersion`). `StudioLibrary.servedURL` regenerates any canvas whose file lacks the current marker, so host-page fixes reach canvases already on disk without waiting for the agent to re-file. Bump the version whenever the host CSS/JS changes behaviour.
- Artboards flow in a row-wrapping grid, labelled by variant name; `width`/`height` from the tool set a fixed frame, otherwise the artboard sizes to content.
- Each `.studio-artboard` gets `all: initial; display: block; contain: layout paint; isolation: isolate;` so nothing inherits *in* from the host page and nothing paints *out* past the artboard.
- **Variant `<script>` is stripped.** Scripts run in the shared document, so a variant's `document.querySelector('.btn')` would find its neighbour's button. The canvas presents variants; CSS interactivity (`:hover`, `:focus`, transitions) is preserved, JS is not. Agents that need JS should file an `agenthub_artifact` instead. The tool description says so.
- The panel resolves *which* variant a clicked element belongs to by evaluating `document.querySelector(cssSelector)?.closest('.studio-artboard')?.dataset.variant` from the element context Canvas already provides.

### CSS scoping — `StudioCSSScoper`

Because everything shares one document, **we own CSS isolation.** `@scope` would be the clean answer but is unavailable on the `macOS 14` deployment floor, so each variant's CSS is rewritten rule by rule. The scoper lives in `AgentHubCLIKit` so the tool boundary and the writer share one implementation and one set of tests.

Input: the variant's `css` plus every `<style>` block hoisted from its `html`. `S` = `.studio-artboard[data-variant="{name}"]`.

| Construct | Rewrite |
|---|---|
| plain rule `a, .b > c {…}` | each comma-separated selector prefixed: `S a, S .b > c {…}` |
| `:root`, `html`, `body` (alone or as the leftmost compound) | replaced by `S` — so `body { background }` paints the artboard, and `:root { --x }` custom properties land on the artboard and inherit down |
| `*` at leftmost | `S *` |
| `@media`, `@supports`, `@container`, `@layer` | preserved; recurse into the block |
| `@keyframes name` | renamed `name-{variant-slug}`; every `animation` / `animation-name` in that variant's declarations rewritten to match |
| `@font-face` | hoisted unchanged (global by nature; identical families across variants share, differing `src` for the same family — last wins; documented) |
| `@import`, `<link rel=stylesheet>` | dropped and reported: the tool returns a warning naming what was dropped, because remote CSS can't be scoped |
| `!important` | preserved |
| inline `style=""` | untouched — already element-scoped |
| unbalanced braces / unparseable | **tool error** ("variant 'ghost' CSS did not parse at byte N") |

Duplicate `id`s across variants are tolerated: `S #x` still resolves per artboard, and browsers cope with duplicate ids. Not rewritten.

Tests are table-driven, one case per row above, plus a leak test: two variants each styling `button { color }` render with different computed colors.

## `agenthub_get_artifact` — the agent's view of the current canvas

`StudioDocumentWriter.write` also writes `artifact.json` beside `index.html` (the full `StudioArtifact` payload, including baked-in edits and saved tweak defaults), and the index entry carries `payloadPath`. `agenthub_get_artifact(id, variant?, includeContent?)` reads that sidecar — never SQLite — and returns metadata plus, for the named variant (case-insensitive) or with `includeContent`, the html/css. This is what makes choosing a variant *in chat* equivalent to clicking Implement, and it lets an agent re-file an existing canvas starting from what the user has rather than what it originally filed.

## Codex approval mode for the bundled server

Codex (0.1xx+) prompts per MCP tool call unless the server's tools are marked `auto` (`mcp_servers.<name>.default_tools_approval_mode`; values `auto | prompt | writes | approve`). Under `approval_policy = never` — a common global setting — a prompt is impossible and the call fails with *"MCP tool call requires approval, but approval policy is never"*, which is how Studio first surfaced this. AgentHub's Codex bootstrap now sets the bundled `agenthub` server to `auto` unconditionally (its tools are AgentHub's own and local), and XcodeBuildMCP to `auto` when the effective policy is `never` / `full-auto` — AgentHub's own Codex setting when one is chosen, otherwise the user's global `approval_policy` read from `~/.codex/config.toml` (`CodexGlobalConfigReader`, top-level key only, honours `CODEX_HOME`, read-only). Older Codex ignores the key; newer rejects unknown values, so only `auto` is emitted. Surfaced when Codex 0.148 (Aug 2026, "Enforce strict auto-review for MCP tool calls" / Guardian v2) introduced per-tool MCP approval; sessions on 0.134–0.147 ran the same tools under `never` without a prompt. Every tool on the bundled server also carries MCP annotations (`AgentHubMCPServer.toolAnnotationsByName`: `readOnlyHint` on the list/get/planning tools, `destructiveHint` only on worktree deletion, `openWorldHint: false` everywhere), so a host on Codex's `writes` mode — "prompts for tools that aren't marked read-only" — does not prompt just to list what exists.

## Getting agents to reach for it

Tool descriptions alone are advisory, and both of Studio's nouns are also claimed by surfaces the model knows well (Claude Code's `/design` skill and `Artifact` tool), so without help the model edits files or publishes elsewhere and nothing lands in the panel. Three layers, strongest first:

1. **System-prompt guidance** — `StudioAgentGuidance.systemPrompt`, injected on the same channel as the simulator guidance (`combinedAppendSystemPrompt` → Claude `--append-system-prompt`, Codex `-c developer_instructions=`) whenever the bundled `agenthub` MCP server is attached. Default-on; Settings › Studio › *Nudge agents toward Studio* turns it off (`AgentHubDefaults.studioAgentGuidanceEnabled`). Never injected without the CLI present — guidance naming tools that do not exist misleads.
2. **Bundled `agenthub-studio` skill** — installed alongside the task-manager skill into `~/.claude/skills/` and `~/.codex/skills/` (`AgentHubStudioSkillInstaller`, shared writer `AgentHubBundledSkillFiles`). Model-invocable from its description *and* an explicit `/agenthub-studio` trigger; the fuller playbook (which tool, how to shape variants and shared props, how to handle feedback and Promote).
3. **Tool descriptions** lead with the user's phrasings ("show me 4 versions", "compare dense vs airy", "what would it look like").

## Discovery — `agenthub_list_artifacts` and `StudioIndexStore`

Same shape as `MeasurementIndexStore`. The app republishes a JSON index per project on every change (`CLISessionsViewModel.publishStudioIndex`), mirrored to every session path that resolves to the project (worktrees included), file names percent-encoded. Entry: `id`, `kind`, `title` / `component`, `variantNames`, `sourcePath`, `revision`, `updatedAt`, `url`. **The CLI reads the index; it never opens the app's SQLite database.**

## Feedback prompts

Two builders, two intents, never one button that does either:

- **`StudioFeedbackPromptBuilder`** (Send) — element context from `ElementInspectorPromptBuilder`, stamped with `variant` when on a canvas, then the user's comment. Closes with: *re-file with `agenthub_design`/`agenthub_artifact` using id `{id}`. Do not edit project files.*
- **`StudioPromotionPromptBuilder`** (Promote…) — names the variant, includes its **original** unscoped `html`/`css` fragment (never the scoped rewrite), the `component` name, and `sourcePath` when the agent supplied one. Asks the agent to implement it in the real component, preserving behaviour and props and changing presentation only, and to report the files it touched. Nothing else in Studio can produce this prompt.

The agent's own permission model still gates any file write; Promote is a prompt, not a mutation.

## Storage & lifecycle

- **Overwrite in place.** A re-file writes `studio/{project}/{id}/index.html` over itself. Same `id` → same directory, so iterating on a canvas fifty times costs one directory. No on-disk revision history: HTML payloads are large, and the agent can re-file an earlier variant if asked. `revision` in the record is a counter for panel reload, not a history.
- **Delete cascades.** Deleting a record (panel, or Settings) removes its directory. Deleting a project's items removes `studio/{project}/`.
- **Reconcile on launch.** `StudioStorageReconciler` drops directories with no DB row and rows with no directory. A crash between the two writes never leaves either a phantom card or an orphan folder.
- **Settings › Studio** mirrors `MeasurementsSettingsView`: items grouped by project with on-disk size, per-item and per-project delete (confirmed), including projects no longer open in the sidebar. Removing a repo from the sidebar never deletes anything on its own.
- Per-item size is bounded by the tool limits, so total growth is `items × ≤1.5 MB` and visible in Settings. There is no automatic eviction — that would be a silent deletion of something the user may be about to look at.

## Sharing (P3)

- **Export…** writes the served `index.html` where the user chooses. It is self-contained by construction: the canvas host page inlines its own CSS/JS, and the inspector bridge is injected by WKWebView at load, so it never appears in the file. Remote references the agent put in its HTML (images, fonts) stay remote.
- **Copy link** — the localhost URL, with the caveat visible that it dies with the app.
- Hosting/publishing is out of scope. Any future publish path must say plainly, in the UI, that it uploads unreviewed agent-generated HTML.

## Key files

| Area | File |
|---|---|
| Domain model (`StudioArtifact`, `StudioVariant`, `Limits`) | `AgentHubCLI/Sources/AgentHubCLIKit/StudioArtifactModels.swift` |
| Fragment normalizer (strip wrappers/scripts, hoist styles) | `AgentHubCLI/Sources/AgentHubCLIKit/StudioFragmentNormalizer.swift` |
| Shared tweak schema model + parser + CSS value mapping | `AgentHubCLI/Sources/AgentHubCLIKit/StudioTweakProps.swift` |
| CSS scoper (shared by tool boundary and writer) | `AgentHubCLI/Sources/AgentHubCLIKit/StudioCSSScoper.swift` |
| CLI→app file queue (+ `StudioSupportDirectory`) | `AgentHubCLI/Sources/AgentHubCLIKit/StudioArtifactQueue.swift` |
| Agent-readable index (list tool) | `AgentHubCLI/Sources/AgentHubCLIKit/StudioIndexStore.swift` |
| Tool schemas, validation, enqueue, list | `AgentHubCLI/Sources/AgentHubCLI/AgentHubMCPServer.swift` (`fileArtifact`, `fileDesign`, `listStudioArtifacts`) |
| Queue drain | `AgentHubCore/.../Services/StudioArtifactMonitor.swift` |
| Session resolution (Claude/Codex targets) | `AgentHubCore/.../Services/StudioArtifactHandler.swift` |
| Project-keyed model, store/load/delete, index publish, reconcile | `AgentHubCore/.../Services/StudioLibrary.swift` (`StudioPersisting` protocol) |
| Host page composition, naming, delete | `AgentHubCore/.../Services/StudioDocumentWriter.swift` |
| Static serving | `AgentHubCore/.../Services/StudioStaticServer.swift` |
| Orphan reconcile + directory size | `AgentHubCore/.../Services/StudioStorageReconciler.swift` |
| SQLite record (blob payload) | `AgentHubCore/.../Models/StudioArtifactRecord.swift` |
| `v18_create_studio_artifacts` + CRUD | `AgentHubCore/.../Services/SessionMetadataStore.swift` |
| Panel state (`@Observable`, tested) | `AgentHubCore/.../UI/StudioPanelState.swift` |
| Edit-mode state (live edits batched per element) | `AgentHubCore/.../UI/StudioDesignEditState.swift` |
| Panel, inspect toggle, Promote menu, Export / Copy link / Delete | `AgentHubCore/.../UI/StudioSidePanelView.swift` |
| Feedback / promotion / tweaks prompts | `AgentHubCore/.../Services/StudioFeedbackPromptBuilder.swift`, `StudioPromotionPromptBuilder.swift`, `StudioTweaksPromptBuilder.swift` |
| Save-defaults (`saveTweakDefaults`) | `AgentHubCore/.../Services/StudioLibrary.swift` |
| View model glue (`storeStudioArtifact`, `loadStudioArtifacts`, `projectScopeKey`) | `AgentHubCore/.../ViewModels/CLISessionsViewModel.swift` |
| Provider wiring (`studioLibrary`, monitor, handler, launch reconcile) | `AgentHubCore/.../Configuration/AgentHubProvider.swift` |
| Panel case + routing | `AgentHubCore/.../UI/MultiProviderMonitoringPanelView.swift` |
| Button gating + load-on-appear | `AgentHubCore/.../UI/MonitoringCardView.swift` |
| Settings tab (storage + guidance toggle) | `AgentHubCore/.../UI/StudioSettingsView.swift`, `ViewModels/StudioSettingsViewModel.swift` |
| Agent nudge (system prompt) | `AgentHubCore/.../Configuration/StudioAgentGuidance.swift`, wired in `UI/EmbeddedTerminalLaunchBuilder.swift` |
| Bundled skill + installer | `AgentHubCore/.../Resources/AgentHubStudioSkill/`, `Services/AgentHubStudioSkillInstaller.swift` |

## Invariants (preserve when editing)

- **Studio never writes into the user's repo.** Artifacts live in Application Support. This is what makes "render 6 button variants" free of consequence — the moment a canvas can touch `src/`, the user has to review it like a diff instead of glancing at it.
- **Tweaks are per canvas, never per variant.** One schema, one panel, every artboard reads the same `--<name>`. A per-variant knob would break the comparison the canvas exists for.
- **Save defaults edits the payload, never the served file.** Canvas → `props`; document → a verified `dc_set_props` splice. Then `store`, so the cache is regenerated and SQLite stays authoritative.
- **Send iterates the surface; Promote asks for code. Never one button that does either.** `StudioFeedbackPromptBuilder` forbids project edits; `StudioPromotionPromptBuilder` is the only path that requests them, and it is a distinct, explicitly labelled action.
- **Canvas edits bake into the payload; documents go to the agent.** A canvas variant's `html` after Edit mode is the serialized artboard — Implement, `agenthub_get_artifact`, and the next re-file all see the user's edits. Never route canvas edits through the agent "for quality": it is a scratchpad, and an agent applying "make the padding 12px" to a fragment it will later re-file is pure ceremony.
- **Quiet self-writes.** A bake produces a revision the panel expects (`quietRevisionExpectation`); the reload handler keeps the page for that revision and reloads for every other. Reloading under an in-progress edit would drop the selection and toolbar.
- **Promotion sends the original fragment, never the scoped rewrite.** The scoped CSS is an artefact of the canvas; shipping `.studio-artboard[data-variant=…]` selectors into someone's codebase would be an embarrassment.
- **A re-file must reuse the same `id`**, which replaces the item in place instead of stacking near-duplicates — same rule and reason as a measurement re-run. `createdAt` is preserved so the item holds its position under the user's cursor.
- **Artifacts are documents, variants are fragments.** `agenthub_artifact` HTML is served verbatim — it needs no scoping, no pan/zoom, no host chrome, and it may need its own `<head>`. `agenthub_design` variants are stripped to fragments and composed into the host page, whose `<head>`, canvas transform, and layout AgentHub owns.
- **Every artboard's CSS is scoped at wrap time, and unscopable CSS is rejected at the tool boundary.** Unscoped variant CSS silently restyles its neighbours, and the resulting canvas lies about what each variant looks like — the only thing the canvas is for.
- **Variant scripts are stripped.** One document, N variants; JS cannot be scoped the way CSS can.
- **Artboards are DOM sections, never iframes**, while `ElementInspectorBridge` is `forMainFrameOnly: true`. If that ever changes upstream in Canvas, revisit — but do not ship iframes and a broken inspector.
- **Payload limits are enforced at the tool boundary**, not in the UI — an over-limit call is a correctable tool error, never a silent truncation.
- **Never store against a `pending-` session id.** Unresolvable records stay queued and are retried (30s), same as `MeasurementRecordMonitor.shouldRetry`.
- **Project-scoped, not session-scoped.** `sessionId` is provenance only. Worktrees roll up via `MeasurementProjectScope`.
- **`webView` is captured deferred.** `onWebViewReady` fires from `makeNSView`; a synchronous `@State` write there is dropped by SwiftUI, and every `setProp`/snapshot then silently talks to nil. Same rule web preview follows.
- **The static server binds `127.0.0.1` only, serves only under `studio/`, and refuses `..`.** Studio content is unreviewed agent-generated HTML; it must not be reachable off the machine, and the server must not be a file-read primitive.
- **The CLI never opens the app's database.** `agenthub_list_artifacts` reads the JSON index.
- **Overwrite in place; delete cascades; reconcile on launch.** Disk usage is `items × bounded size`, visible in Settings, and never silently evicted.
- **Record stored as an encoded blob with `payloadVersion`** — the sanctioned per-table version column, because the item's shape will evolve independently of the schema.
- **New migration only.** `v18_*`; never edit or reorder `v1`–`v17`. Migration-preservation tests anchor on an identifier via `seedMigrationBaseline(before:in:)` — never a positional `dropLast(n)`.

## Tests

| Suite | Package | Covers |
|---|---|---|
| `StudioCSSScoperTests` | CLI | one case per rewrite-table row; leak test; parse-failure error carries offset |
| `StudioFragmentNormalizerTests` | CLI | wrapper stripping, style hoist, script/link drop + warnings |
| `StudioArtifactQueueTests` | CLI | atomic write, drain order, tmp/failed handling, `replacing` semantics |
| `StudioIndexStoreTests` | CLI | percent-encoded names, mirror to alias paths |
| `StudioTweakPropsTests` | CLI | every prop type, array/object forms, bool-vs-1 disambiguation, rejections, CSS values, tolerant decoding |
| `StudioDocumentWriterTests` | Core | document verbatim; canvas artboards in order, labels, sizes, escaping; unsafe ids hashed; cascade delete |
| `StudioStaticServerTests` | Core | 127.0.0.1 only, index.html resolution, `..`/dotfile/escape → 404, HEAD/405, `no-store`, live socket |
| `StudioArtifactHandlerTests` | Core | explicit id (Codex), process-group fallback, `pending-` fallback, retry window |
| `StudioStorageReconcilerTests` | Core | orphan dirs dropped, empty projects removed, missing root no-op |
| `StudioPromptBuilderTests` | Core | variant stamped; forbids project edits; promotion carries unscoped source + `sourcePath` |
| `StudioPanelStateTests` | Core | default/explicit selection, reload token, follow-the-agent reconcile, variant-from-selector |
| `StudioDesignEditStateTests` | Core | per-element batches with old→new deltas, last-wins, revert cancels, delete/fit, refresh keeps edited values, late variant stamp |
| `StudioLibraryTests.updateVariantHTMLBakesEdits` | Core | bake replaces only named variants, bumps revision, republishes the payload sidecar + `payloadPath` |
| `StudioLibraryTests` | Core | store/refile/load/delete/deleteAll, index publish, servedURL rewrite, allProjects, reconcile |
| `StudioArtifactStoreTests` | Core | SQLite round trip, upsert, project scoping, v18 preserves the v17 baseline |
| `StudioTweaksTests` | Core | host page CSS vars + schema + escaping; save-defaults canvas (revision bump, other props kept) and document (spliced call); tweaks prompts |
| `CLISessionsViewModelStudioTests` | Core | Codex-filed artifact visible to a Claude session in the same project; re-file/delete through the view model; no-project drop |

The view itself has no snapshot test; everything the view decides lives in `StudioPanelState`, which does.

## Current state — works

- All three tools on the bundled MCP server, available in every AgentHub-managed Claude and Codex session with no configuration (rides the existing `AGENTHUB_*` bootstrap for both providers).
- Tool-boundary validation: limits, unique variant names, fragment normalization with warnings, CSS scoping check with character offset on failure.
- Queue → monitor → handler (Claude/Codex targets, `pending-` retry) → shared `StudioLibrary` → SQLite (`v18`) + served document + JSON index.
- In-process loopback server; canvas host page with pan/zoom (wheel, ⌘±/⌘0, drag on empty canvas, HUD with Fit); per-variant CSS isolation verified visually.
- Panel: picker, Inspect toggle with element-anchored comment box, Send (variant-stamped feedback prompt), Promote… per variant, **Tweaks** (shared props on a canvas; `dc_set_props` in a document; live values, Reset, Save defaults, Ideas / Custom / Delete all through the session), Reload, Open in browser, Copy link, Export…, Delete, warnings banner, expand/collapse.
- Shared canvas tweaks verified visually: one change moved radius, accent, label, and shadow across all variants at once.
- Settings › Studio: per-project list with bytes on disk, per-item and per-project delete.
- Launch reconcile of orphan directories; missing documents rewritten from the payload on demand.

## Remaining work / gaps

- [ ] **No auto-open, by design** — but there is also no *notification* that something landed. A subtle badge pulse on the Studio button when a new item arrives would help without violating the rule.
- [ ] **Promote does not verify.** The agent is asked to report files touched; nothing checks that it stayed within `sourcePath`.
- [ ] **Alias index staleness from Settings.** Deleting from Settings republishes the project key's index but not worktree aliases (no session context there); a worktree's `agenthub_list_artifacts` can name a deleted item until its project is next loaded.
- [ ] **Tweaks in a document need cooperation from the agent.** A document only gets the panel if it calls `dc_set_props`; nothing enforces it. Canvas props need no agent cooperation beyond declaring them.
- [ ] **CSS scoping edge cases.** `@font-face` collisions across variants (last wins), CSS nesting with `&` inside `@media` blocks, and duplicate `id`s across variants are tolerated, not solved.
- [ ] **Canvas layout is flow-only.** Artboards wrap at the panel width at load; there is no persisted per-artboard position, no drag-to-arrange, and no zoom/pan persistence across reloads.
- [ ] **Sharing beyond Export.** Hosting is out of scope; any future publish path must say in the UI it uploads unreviewed agent HTML.

## Verification

- CLI: `cd app/modules/AgentHubCLI && swift test --filter Studio`
- Core: `cd app/modules/AgentHubCore && xcodebuild test -scheme AgentHubCore-Tests -destination 'platform=macOS' -test-timeouts-enabled YES -skipPackagePluginValidation -only-testing:AgentHubTests/StudioDocumentWriterTests -only-testing:AgentHubTests/StudioStaticServerTests -only-testing:AgentHubTests/StudioArtifactHandlerTests -only-testing:AgentHubTests/StudioStorageReconcilerTests -only-testing:AgentHubTests/StudioPromptBuilderTests -only-testing:AgentHubTests/StudioPanelStateTests -only-testing:AgentHubTests/StudioLibraryTests -only-testing:AgentHubTests/StudioArtifactStoreTests`
- Manual tool drive (no app needed): set `AGENTHUB_PROVIDER=claude AGENTHUB_SESSION_ID=<id> AGENTHUB_PROJECT_PATH=<repo>` and pipe JSON-RPC `tools/call` lines into `agenthub mcp-server`; the record lands in `studio-records/` for the app to drain.
