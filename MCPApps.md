# MCP Apps

AgentHub renders **MCP app UIs** (interactive `text/html;profile=mcp-app` resources) that an agent produces during a monitored session — e.g. an excalidraw diagram from `mcp__excalidraw__create_view`. The guiding principle:

> **An MCP app is the _output of an agent tool call_, rendered where the work happened — not something AgentHub launches out-of-band.**

AgentHub is an *observer* of the CLI's session (it reads JSONL); it is **not** the MCP host the CLI talks to. But the app shell HTML and the tool→app mapping live on the MCP **server**, not in the transcript, so AgentHub acts as a *minimal, lazy MCP Apps host*: it detects an app-bearing tool call in the JSONL, fetches that one server's shell on demand, renders it, and pushes the call's data into it.

This works for **Claude and Codex** sessions and for any MCP app built on the standard MCP Apps SDK (the convention excalidraw, pencil, etc. use).

## User behavior

- A session's monitoring card shows an **MCP** button only after the agent has produced an MCP app (no proactive discovery, no "server unreachable" noise).
- Clicking it opens a dedicated **side panel** (alongside Diff / Plan / WebPreview) that renders the app and seeds it with the tool call's data so it draws immediately.
- A picker switches between multiple apps/edits; labels come from the app's own content (e.g. "Login Flow") with an ordinal when several share a title.
- If the rendered app calls a tool back (e.g. excalidraw `read_checkpoint`), the user is asked for **consent** before AgentHub contacts the server.

## Two rendering paths

1. **Host path (primary).** The agent calls a tool whose `tools/list` `_meta` declares `ui.resourceUri` (e.g. `ui://excalidraw/mcp-app.html`). The transcript has only the tool **input** (arguments) and **result** — never the shell HTML. AgentHub resolves the shell from the server and pushes the data in. Keyed by `SessionMonitorState.detectedMCPAppInvocations`.
2. **Embedded path.** Some servers embed the full `ui://` resource (HTML in `text`) directly in the tool result. AgentHub renders it as-is, no server contact. Keyed by `SessionMonitorState.detectedMCPAppResources`.

The side panel shows both; only the host path needs a `tool-input`/`tool-result` push.

## Data flow (host path)

```
Claude:  tool_use(mcp__excalidraw__create_view, input=elements)  +  tool_result({checkpointId})
Codex:   event_msg mcp_tool_call_end { invocation{server,tool,arguments}, result.Ok{content} }
   │
   ├─ Parser captures MCPAppInvocation{server,tool,arguments,result}        ①
   │     SessionJSONLParser (Claude: correlate tool_use/tool_result by id)
   │     CodexSessionJSONLParser (single mcp_tool_call_end event)
   │  → SessionMonitorState.detectedMCPAppInvocations
   │
   ├─ ViewModel resolves lazily, scoped to used servers                     ②
   │     ensureMCPAppRenderItems(): tools/list → _meta.ui.resourceUri,
   │     then resources/read the shell once (cached). On-demand only.
   │
   ├─ MCP button gates on mcpAppDisplayItems; side panel renders shell      ③
   │     MultiProviderMonitoringPanelView (.mcpApp) → MCPAppSidePanelView
   │
   └─ Bridge pushes data once the app has mounted                           ④
         on first ui/notifications/size-changed:
           ui/notifications/tool-input   { arguments }            → app draws
           ui/notifications/tool-result  { content, structuredContent }
         app callbacks (tools/call) → consent → on-demand gateway
```

## Key files

| Area | File |
|---|---|
| Side panel, host view, bridge handler, consent controller | `Sources/AgentHub/UI/MCPAppSidePanelView.swift` |
| `.mcpApp` side-panel case + card wiring | `Sources/AgentHub/UI/MultiProviderMonitoringPanelView.swift` |
| MCP button gating + lazy-resolution `.task` | `Sources/AgentHub/UI/MonitoringCardView.swift` |
| Resolution, caches, render items, title derivation, on-demand calls | `Sources/AgentHub/ViewModels/CLISessionsViewModel.swift` |
| On-demand JSON-RPC gateway (callTool/readResource/listResources/listTools, client pool) | `Sources/AgentHub/Services/MCPAppDiscoveryService.swift` |
| Server config (`~/.claude.json`, `~/.codex/config.toml`) | `Sources/AgentHub/Services/MCPServerConfigurationResolver.swift` |
| Embedded-resource extraction + `serverName(fromToolName:)` | `Sources/AgentHub/Services/MCPAppResourceExtractor.swift` |
| Claude invocation capture | `Sources/AgentHub/Services/SessionJSONLParser.swift` |
| Codex invocation capture (`mcp_tool_call_end`) | `Sources/AgentHub/Services/CodexSessionJSONLParser.swift` |
| `MCPAppInvocation`, `MCPAppRenderItem`, `MCPAppResource`, JSON↔Any converters | `Sources/AgentHub/Models/MCPAppResource.swift` |
| `detectedMCPAppInvocations` on monitor state | `Sources/AgentHub/Models/SessionMonitorState.swift` |
| WKWebView bridge coordinator + `appReadyNotifications` push hook | `Sources/AgentHubMCPUI/AgentHubMCPUIResourceView.swift` |

## Invariants (preserve when editing)

- **No proactive discovery.** AgentHub must not spawn/contact MCP servers on session activity. Server contact (`tools/list`, `resources/read`, `tools/call`) happens only lazily, scoped to a server the agent actually used, triggered by a real tool call.
- **Resolution keys off the standard `_meta.ui.resourceUri`** (and the `ui/resourceUri` alias) — server/tool-agnostic. No app names hardcoded.
- **The SDK drops notifications sent before its handlers register.** The app registers `ontoolinput` in a mount effect that runs *after* it sends `ui/notifications/initialized`, so deliver `tool-input`/`tool-result` on the first `ui/notifications/size-changed` (mounted), with a delayed fallback. Delivery is once-per-loaded-resource (`didDeliverReadyNotifications`).
- **Consent must never hang.** `MCPAppConsentController` auto-denies after a timeout and is cancelled (`cancelPending`) on panel dismiss / resource switch; resolution is guarded against double-resume.
- **CSP allowlists are derived from untrusted output → default-deny + consent.** An app's declared `_meta.ui.csp` / `openai/widgetCSP` domains arrive in the same tool output as its HTML, so the WKWebView loads `.lockedDown` by default (`MCPAppNetworkTrust` in `AgentHubMCPUIResourceView`): no remote script/connect/resource loads at all. Every remote directive — **including `script-src`** (real apps load their runtime as ES modules from a CDN, e.g. excalidraw imports React from `esm.sh`, and `script-src` governs module imports) — widens **only** after one explicit per-resource user opt-in (the network-consent banner in `MCPAppResourceHostView`), and only to validated http(s) hosts (`domainSources`). `'unsafe-inline'` is always present because the HTML body *is* the app; the real controls are the sandbox (non-persistent store, no file/host access, gated navigation) + this per-app consent gate on all egress. Consent resets on resource switch. Do not widen any directive in the locked-down branch.
- **Codex MCP host rendering needs the server in `~/.codex/config.toml`.** Capture works regardless, but shell resolution uses the Codex provider's config.
- Changes here need unit tests (capture, resolution, bridge push, tool-result shaping, consent).

## Current state — works

- Agent-driven side panel for **Claude and Codex**, verified live (excalidraw login-flow diagram renders under both).
- Lazy, scoped server resolution; on-demand callback gateway (stdio + HTTP/SSE).
- `tool-input`/`tool-result` push with race-safe timing; `structuredContent` derived from JSON-string / Codex `Ok`-wrapped results.
- Consent timeout/auto-deny/cancel; content-derived picker labels.
- Tests: `SessionJSONLParserMCPAppInvocationTests`, `CodexSessionJSONLParserMCPAppInvocationTests`, `CLISessionsViewModelMCPAppDiscoveryTests`, `MCPAppSidePanelViewTests`, `MCPAppDiscoveryServiceTests`.

## Remaining work / gaps

- [ ] **No failure feedback.** When `tools/list`/shell-read fails (server unreachable or not in config), the button silently never appears — only a `[MCPAppHost]` log line. Surface "couldn't load this MCP app" in the panel.
- [ ] **OpenAI Apps SDK apps not supported.** They use `_meta["openai/outputTemplate"]` + `window.openai.*` instead of `_meta.ui.resourceUri` + `ui/notifications/*`. Add the metadata-key alias (small) and the data API (larger).
- [ ] **Tool-call consent doesn't persist across panel reopens.** `MCPAppConsentController` grants (callTool/readResource/openLink) are per-instance; reopening re-prompts on the first callback. (Network-access consent *does* persist per app launch — `CLISessionsViewModel.grantMCPAppNetwork`, keyed by server + declared host set; not yet across restarts.) Consider unifying both onto a launch-/disk-scoped "allow for this app".
- [ ] **`restoreCheckpoint` default.** The newest invocation can be a restore that needs a `read_checkpoint` callback (→ consent) before anything draws. Consider defaulting selection to a full-elements invocation.
- [ ] **Auto-open deferred.** Panel is button-only; doesn't pop when a new app is produced. Route through `MonitoringAutoOpenSidePanelPolicy` if wanted.
- [ ] **Title derivation is excalidraw-shaped** (`elements`/`text`); other apps fall back to the generic tool title.
- [ ] **No streaming.** We push the final `tool-input` once, not `ui/notifications/tool-input-partial` (no progressive draw — cosmetic).
- [x] **CSP hardening.** The shell's `_meta` CSP is untrusted, so the web view is default-deny (`.lockedDown`); `script-src` is never widened, and connect/resource domains widen only after an explicit per-resource consent banner. See the CSP invariant above. Tests: `MCPAppCSPHardeningTests` (CSP directives) and `MCPAppSidePanelViewTests` (banner host parsing/visibility).
- [ ] **No automated test for the bridge timing fix** (deliver-on-size-changed is WKWebView-level; validated by reasoning + live run).

## Verification

- Build: `xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub build`.
- Core tests run via Xcode **Cmd+U** (headless `swift test` skips UI suites needing the CodeEditSymbols bundle; the MCP logic suites do run headless via `swift test --filter`).
- End-to-end: in a monitored Claude **or** Codex session whose CLI has an MCP app server configured, prompt the agent to produce one (e.g. "draw a diagram of the login flow"). The MCP button should appear after the tool call; the panel should render the artifact. Logs show `[MCPUIBridge] host->app ready-notification method=ui/notifications/tool-input` **after** a `size-changed`.
