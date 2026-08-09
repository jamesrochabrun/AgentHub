# Measurements Panel

AgentHub renders **measurements** an agent produced during a session — a claim, the numbers behind it, and the query that produced them — in a dedicated side panel. The guiding principle:

> **A number a PM will decide on must arrive with its query and its caveats attached. The agent supplies data; AgentHub draws it.**

This is the data-analysis counterpart to the web/simulator preview panels: those exist to build, this exists to decide.

## On the name

Called **Measurements** deliberately, after trying "Evidence" and "Findings". The test a name has to pass here is covering *both* kinds of card: a one-off answer ("which files churn most" — a ranking, not a metric) and a metric tracked over time ("clean build time"). "Metrics" only fits the second and implies a live dashboard that does not exist; "Insights" promises interpretation and fights the show-the-query principle; "Snapshots" collides with snapshot testing (SnapshotPreviews is a dependency). Measurements is the plainest word that fits every card.

## User behavior

- A session's monitoring card shows an **Measurements** button only after the agent has filed at least one measurement (no proactive UI, same rule as the MCP button).
- Clicking it opens a side panel listing cards newest-first: title, the claim in plain English, a chart, an optional table, caveats, and the query collapsed underneath.
- Cards persist across relaunch and are scoped to the session that produced them.
- The panel never auto-opens — it is button-only (`isAutoOpenableContent` returns `false` for `.measurements`).

## Data flow

```
agent calls agenthub_record_measurement(title, claim, chart|table, query, caveats, source)
   │
   ├─ AgentHubMCPServer validates + enqueues                                ①
   │     recordMeasurement() → MeasurementRecordQueue (JSON file, atomic write)
   │     ~/Library/Application Support/AgentHub/measurement-records/
   │
   ├─ App drains the queue                                                  ②
   │     MeasurementRecordMonitor (poll) → MeasurementRecordHandler
   │     resolves AGENTHUB_SESSION_ID, else process→session mapping
   │
   ├─ ViewModel stores it                                                   ③
   │     CLISessionsViewModel.storeMeasurement(): in-memory first (card appears
   │     immediately), then SessionMetadataStore.saveMeasurement()
   │
   └─ Panel renders                                                         ④
         MonitoringCardView gates the button on measurementCount
         → SidePanelContent.measurements → MeasurementsSidePanelView
         → MeasurementCardView → MeasurementChartView (Swift Charts)
```

## Key files

| Area | File |
|---|---|
| Record/chart/table models + limits | `AgentHubCLI/Sources/AgentHubCLIKit/MeasurementModels.swift` |
| CLI→app file queue | `AgentHubCLI/Sources/AgentHubCLIKit/MeasurementRecordQueue.swift` |
| Tool schema, validation, enqueue | `AgentHubCLI/Sources/AgentHubCLI/AgentHubMCPServer.swift` (`recordMeasurement`, `recordMeasurementToolSchema`) |
| Queue drain | `AgentHubCore/.../Services/MeasurementRecordMonitor.swift` |
| Session resolution | `AgentHubCore/.../Services/MeasurementRecordHandler.swift` |
| SQLite record (blob payload) | `AgentHubCore/.../Models/SessionMeasurementRecord.swift` |
| `v14_create_session_measurements` + CRUD | `AgentHubCore/.../Services/SessionMetadataStore.swift` |
| In-memory state, merge, load/delete | `AgentHubCore/.../ViewModels/CLISessionsViewModel.swift` |
| Panel, card, chart | `AgentHubCore/.../UI/MeasurementsSidePanelView.swift`, `MeasurementCardView.swift`, `MeasurementChartView.swift` |
| Panel case + routing | `AgentHubCore/.../UI/MultiProviderMonitoringPanelView.swift` |
| Button gating | `AgentHubCore/.../UI/MonitoringCardView.swift` |
| Re-run prompt | `AgentHubCore/.../Services/MeasurementRerunPromptBuilder.swift` |
| Project bucket + worktree rollup | `AgentHubCore/.../Services/MeasurementProjectScope.swift` |
| Branch-split trend | `AgentHubCore/.../Services/MeasurementTrendBuilder.swift` |
| Agent-readable index (list tool) | `AgentHubCLI/Sources/AgentHubCLIKit/MeasurementIndexStore.swift` |
| Axis label rule | `MeasurementAxisLabelLayout` in `MeasurementChartView.swift` |

## Invariants (preserve when editing)

- **The agent sends data, never markup.** `agenthub_record_measurement` accepts a chart *specification* (series of `{x, y}` points) and AgentHub draws it with Swift Charts. Do not add an HTML/SVG/image passthrough: it would put agent-authored markup in the panel, break theming, and make cards unre-runnable.
- **A measurement needs numbers.** The tool rejects a call with neither `chart` nor `table`. A text-only "measurement" is an assertion, not evidence of anything.
- **Caveats are not small print.** They render as their own visually distinct block. The panel exists so a number arrives with the reasons it might mislead attached; do not demote them to a tooltip or a footer.
- **Payload limits are enforced at the tool boundary** (`MeasurementRecord.Limits`), not in the UI. Exceeding one is a tool-level error the agent can correct by aggregating — never a silent truncation, which would make a card lie about its own coverage.
- **Never store measurements against a `pending-` session id.** That id is replaced when the session becomes real, stranding the card. Unresolvable records stay queued and are retried for 30s (`MeasurementRecordMonitor.shouldRetry`).
- **The record is stored as an encoded blob** with `payloadVersion` — the one sanctioned per-table version column, because the card's shape evolves independently of the schema. Only queried-on columns are denormalized.
- **Measurements are scoped to a project, never to a session.** A measurement about a repo or a database outlives the conversation that produced it; session scoping would hide last month's number from this month's work, which is exactly when it matters. `sessionId` is retained as provenance only and must not be used to decide what the panel shows. Worktrees roll up to their parent repo via `MeasurementProjectScope`, so a worktree's runs join the repo's history instead of forming an isolated set.
- **Re-run accumulates, it does not overwrite.** `replacing(_:)` pushes the superseded values onto `history` (capped at `Limits.maxHistoryRuns`). Losing the old numbers would destroy the only thing that makes a re-run worth doing.
- **Never colour the delta red/green.** Whether "up" is good depends on the metric — down is good for build time, bad for weekly actives — and AgentHub is not told which. The sign alone is unambiguous; a colour would confidently mislead half the time.
- **The CLI never opens the app's database.** `agenthub_list_measurements` reads a JSON index the app republishes on every change (`CLISessionsViewModel.publishMeasurementIndex`). Opening SQLite from the helper would couple it to the app's schema and its single-process assumptions. The index is mirrored to every session path that resolves to the project, so a worktree session finds it from `AGENTHUB_PROJECT_PATH` alone.
- **Index file names are percent-encoded, not separator-substituted.** Turning `/` into `-` makes `/a/b-c` and `/a-b/c` collide, silently merging two projects' measurements.
- **Every run records the branch it measured.** Measurements roll up to the repository, so a `main` run and a feature-worktree run land on the same card. Plotted as one series they interleave — 214, 163, 211, 160 — and two perfectly stable branches read as a metric thrashing. The branch is stamped by the app from the recording session (never by the CLI shelling out to `git`, which is wrong in a detached or mid-rebase checkout), carried into history with the values it measured, and split into one trend series per branch. The delta likewise compares against the previous run *on the same branch*.
- **A category axis needs an explicit order when series cover different categories.** Swift Charts derives the axis from first-appearance order, which groups one branch's dates before the other's and renders them out of chronology. `MeasurementChart.xOrder` states the order; the trend builder sorts it by run date.
- **No auto-open.** The panel is button-only.
- **Re-run goes through the agent, never through AgentHub.** `↻` sends `MeasurementRerunPromptBuilder.prompt(for:)` into the session terminal and the agent re-files the measurement. AgentHub must not execute a stored query itself: the query is arbitrary shell/SQL an agent wrote, and running it from a click would turn a saved card into a code-execution surface. Clicking `↻` can do nothing the session could not already do.
- **A re-run must re-file under the same `id`.** That is what upserts the card in place instead of stacking a near-duplicate. `resolvingRerun` then keeps the original `createdAt` (so the refreshed card holds its position and does not jump under the user's cursor) and stamps `updatedAt`.
- **The re-run prompt forbids rewriting the query**, because the whole point is that the measurement stays comparable across runs, and forbids recording anything if the command fails — a card silently holding stale numbers is worse than one visibly out of date.
- **The pending spinner must have a terminal state.** The agent can simply never call back; `CLISessionsViewModel.rerunTimeout` clears it after 180s so "re-running…" never becomes permanent.
- **Migration-preservation tests must anchor on an identifier**, via `seedMigrationBaseline(before:in:)` — never a positional `dropLast(n)`, which silently breaks the moment a `vN_` migration is appended (this is exactly how v14 broke `ProjectSimulatorPreferenceTests`).

## Current state — works

- `agenthub_record_measurement` on the bundled MCP server, available in every AgentHub-managed Claude/Codex session with no configuration (it rides the existing `AGENTHUB_*` env bootstrap).
- Validated chart (bar/line/area/point, multi-series) and table specs; queue round trip; session resolution by explicit id or process group.
- SQLite persistence with the v14 migration; cards survive relaunch; per-card delete.
- Panel with claim, chart, table, caveats block, collapsible query with copy, source footer.
- Project scoping with worktree rollup, cross-provider sharing, and a v15 backfill for pre-existing rows.
- Branch-aware runs: history rows name their branch (only when runs actually span branches), and the trend splits into one series per branch so a branch comparison reads as a comparison.
- Run history per card (capped), with a trend chart for scalar metrics and every earlier claim retained.
- `agenthub_list_measurements`, so an agent can refresh an existing measurement by name instead of filing a near-duplicate.
- Tests: `MeasurementRecordQueueTests` and `MeasurementIndexStoreTests` (CLI package), `SessionMeasurementStoreTests`, `MeasurementRunHistoryTests`, `MeasurementProjectScopeTests`, `MeasurementsMergeTests`, `MeasurementRerunTests`, `MeasurementAxisLabelLayoutTests`, `MeasurementRecordHandlerTests`.

## Remaining work / gaps

- [ ] **Re-run needs a live session.** `↻` is hidden when the session has no active terminal, so a measurement from a closed session cannot be refreshed. Reopening the session restores it.
- [ ] **Nothing verifies the agent actually re-ran the query.** It is asked to run it verbatim; a lazy agent could re-derive it. Detecting that would mean hashing the executed command.
- [ ] **Branch names are not reconciled.** A renamed or deleted branch keeps its old name in history, and two unrelated repos' branches sharing a name is not a concern here only because measurements are already project-scoped.
- [ ] **No scheduled refresh.** Re-running is manual: if nobody opens the panel and clicks `↻`, a tracked metric silently goes stale. Automatic refresh would make a card a real tracked metric, and needs a scheduler plus a policy for when it may run.
- [x] **Data connectors — solved by MCP, not by us.** External data arrives through whatever MCP servers the user has configured in their own agent (`~/.claude.json`, `~/.codex/config.toml`). AgentHub builds and maintains no connectors, never sees credentials, and never moves rows: it reads a JSON file off disk and draws a chart. The privacy claim narrows accordingly and should be stated plainly — *AgentHub sends nothing; what a user's own MCP servers send is their configuration and their call.*
- [ ] **No provenance/semantic layer.** `source` is free text. A `.agenthub/metrics.yml` that the agent must resolve named metrics through is what turns a card from "trust me" into "checkable".
- [ ] **No skeptic pass.** Nothing checks sample size, null rate, join fan-out, or partial windows automatically — the caveats are only as good as the agent's honesty.
- [ ] **No segment decomposition.** The "who's under this average?" action is not built.
- [ ] **No export.** Cards can't be exported as a shareable report.
- [ ] **Chart x axis is categorical only.** Dates are labels, so spacing is even regardless of real gaps. Fine for cohorts/buckets, wrong for irregular time series.
- [ ] **Single-number measurements render badly.** "Build time is 163s" draws as one lone bar, and with history the card then shows that same number twice — once as a bar, once as the trend. A scalar wants a big-number layout plus the trend, not a bar chart.
- [ ] **Direction-of-good is unknown.** The delta is uncoloured because nothing tells AgentHub whether up is good. A `higherIsBetter` flag on the tool would let the card say so safely.
- [ ] **Measurements are not deleted when a project is removed.** `deleteAllMeasurements(forProjectPath:)` and `deleteUnscopedMeasurements()` exist but nothing calls them — deliberately, since removing a repo from the sidebar is reversible and should not destroy its history. Needs an explicit user-facing action instead.
- [ ] **No panel-level tests.** UI is covered indirectly (view model + store); `MeasurementsSidePanelView` itself has no snapshot/behavior test.

## Verification

- CLI: `cd app/modules/AgentHubCLI && swift test --filter MeasurementRecordQueue`
- Core: `cd app/modules/AgentHubCore && xcodebuild test -scheme AgentHubCore-Tests -destination 'platform=macOS' -test-timeouts-enabled YES -skipPackagePluginValidation -only-testing:AgentHubTests/SessionMeasurementStoreTests -only-testing:AgentHubTests/MeasurementRecordHandlerTests -only-testing:AgentHubTests/MeasurementsMergeTests`
- End-to-end: in a monitored session, ask the agent to analyze a local CSV and record the result. The Measurements button should appear on the card; the panel should render the chart with the query collapsed underneath.
- Tool only: pipe JSON-RPC into the built CLI with `AGENTHUB_PROVIDER`/`AGENTHUB_SESSION_ID` set and inspect `~/Library/Application Support/AgentHub/measurement-records/`.
