# Simulator Preview (live in-app iOS Simulator)

Read this before editing the live simulator preview: the `SimulatorPreview`
module, `SimulatorPreviewSidePanelView`, the `.simulator` side-panel case, the
`onShowSimulatorPreview` card callback, or `AgentHubProvider.simulatorStreamService`.
The **hot reload + Previews tab** layer has its own section below — read it
before touching anything named `HotReload*`, `PreviewHost*`, or
`SimulatorHotReloadController`.

## What it is

Renders a **live, interactive iOS Simulator inside AgentHub's side panel** — the
same capability Codex shipped via its "Build iOS Apps" plugin (which used
`serve-sim` + `SnapshotPreviews`), but native, in-process, and private by default.

The user clicks **Simulator** (shown only for Xcode projects). The side panel lets
them pick/boot a simulator and Build & Run, then mirrors the simulator's screen
and forwards mouse/keyboard back to it. Connected physical iOS/iPadOS devices are
also valid run destinations: AgentHub can build, install, and launch on them via
`xcodebuild` + `devicectl`, but live mirroring, input forwarding, recording,
annotation, hot reload, and previews remain simulator-only. The old per-card
Simulator button that opened the `SimulatorPickerView` sheet is deprecated: the
panel is now the single entry point, and the management sheet code remains wired
but hidden while it can drift out of sync with the panel picker. Build/run
failures surface directly in the side panel with a send-to-agent action. (The
legacy `MonitoringPanelView` path, which doesn't wire the side-panel callback,
still falls back to the sheet.)

When a physical device is selected, keep the panel quiet: do not warm
hot-reload artifacts, start preview source watchers, arm the preview host, or
display simulator-only hot-reload state.

**Run destinations are project/worktree-scoped.** `SimulatorDestinationResolver`
resolves the panel's device from the explicit in-panel selection, then the
project's persisted preference — and deliberately nothing else: with no
association the panel shows a "Choose a Run Destination" picker rather than
adopting another project's booted simulator or a random connected phone.
Preferences are keyed by `projectPath` (worktrees are distinct paths, so each
worktree remembers its own device) and persisted in `SessionMetadataStore`
(`project_simulator_preferences`, hydrated into `SimulatorService` at launch),
so they survive app relaunches. Do not reintroduce global
`bootedDevices.first`-style fallbacks — that was the "project A shows
project B's simulator" bug.

## Annotation feedback (element-aware pins sent to the agent)

The header's **Annotate** toggle pauses tap forwarding and reads the frontmost
app's **accessibility tree** (`SimulatorAXInspector`): element frames render over
the mirrored screen, hovering highlights the element under the cursor with a
role/size chip, clicks drop numbered pins **bound to that element**, and drag
gestures still forward as simulator touches so scrollable content can be
reached — an inline bubble captures the instruction ("move this to be top
aligned"). Queued
pins collect in a bottom tray — the same interaction model as the web preview's
queued updates — and **Send** delivers one composed prompt to the session
terminal via `onSendToSession`, wired in `MultiProviderMonitoringPanelView` to
`sendPromptToActiveTerminal` with a `showTerminalWithPrompt` fallback (identical
to web-preview inspect feedback).

The composed prompt carries **no intent of its own** — the user's note per pin
is the instruction (it may be a question like "what is this?", not a change
request), the screenshot is offered as optional context ("If you need visual
context…"), never a command to read it, and a single pin collapses to one
compact sentence with no list scaffolding. Element-targeted pins are described
to the agent by **identity only**:
`Button "Safari" (identifier ...): <instruction>` — no coordinates of any kind
when the element has a label/identifier (the agent finds it in source by name;
the stamped screenshot covers the visual). Geometry appears only when identity
is insufficient: duplicated labels get an ordinal + frame ("the 2nd of 2 with
this label, top to bottom — frame ... pt"), anonymous elements get their AX
frame in points, and element-less pins get percent/pixel positions. A header refresh button re-reads the tree after the
app's UI changes. Screenshot capture writes to a temp file path — newer simctl
no longer supports streaming to stdout via `-`.

On send, a one-shot `simctl io screenshot` is captured, the pins are stamped onto
it (`SimulatorScreenshotCapture`, CoreGraphics-only), and it is written to a temp
file whose path is included in the prompt so the agent can read it. Pin positions
are normalized framebuffer coordinates (`SimulatorAnnotation`), which map 1:1
onto the device-resolution screenshot; element frames are in device points
against the AX root (screen) frame (`SimulatorAnnotationPromptBuilder`,
unit-tested). The prompt ends with one **conditional** process footer ("If you
make code changes in response…") pointing the agent at the XcodeBuildMCP verify
loop — added because agents otherwise "validate" with a bare `xcodebuild build`,
which neither updates nor checks the app on screen. The user's note remains the
only instruction in the message.

Sending feedback must never lose the panel: the auto-open side-panel policy
(`openAutoSidePanelIfNeeded` in `MultiProviderMonitoringPanelView`) refuses to
replace any panel the user opened deliberately — auto-open only lands on an
empty slot or on another auto-opened `.edits`/`.plan` surface. Without that
guard, the agent's first edit in response to annotation feedback swapped the
`.simulator` panel for the edits panel.

### How the AX tree is read (`SimulatorAXInspector`)

Adapted from facebook/idb's `FBSimulatorAccessibilityCommands` (MIT). The
host-side private framework
`/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework`
translates the simulated app's AX hierarchy: `AXPTranslator.sharedInstance()`
gets a bridge-token delegate (ours answers each lazy attribute read by a bounded
synchronous wait on CoreSimulator's public-ish
`-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`
XPC, 5s timeout). `frontmostApplicationWithDisplayId:bridgeDelegateToken:`
returns a translation that converts to an `AXPMacPlatformElement` — an
`NSAccessibilityElement` subclass traversed with **public** NSAccessibility API
(role/label/identifier/value/frame/children). All reflective and guarded;
failure degrades to positional pins, never crashes. Traversal is bounded
(depth 50, 2000 elements). Verify live with
`swift run SimulatorAXProbe <booted-udid> [hitX hitY]` (dev-only target;
`AGENTHUB_AX_DEBUG=1` logs the XPC handshake). Note: the simulated app answers
AX queries only while the device is actually booted — a stale "Booted" listing
yields nil translations.

## Where the code lives

- **`app/modules/SimulatorPreview/`** — standalone Swift package (sibling of the
  `Storybook` module). All private-framework capture/HID code is isolated here.
  - `FramebufferCapture` / `HIDInjector` / `CoreSimulatorBridge` — the private-API
    surface (CoreSimulator + SimulatorKit via `dlopen`/`NSSelectorFromString`).
    Adapted from [EvanBacon/serve-sim](https://github.com/EvanBacon/serve-sim)
    (Apache 2.0).
  - `ScreenshotPoller` — public `simctl io screenshot` fallback (view-only).
  - `SimulatorStreamSession` / `SimulatorStreamService` — backend selection +
    per-UDID session reuse.
  - `SimulatorStreamView` — `AVSampleBufferDisplayLayer`-backed `NSViewRepresentable`
    with mouse→touch and keyboard injection.
  - `SimulatorPointMapper` / `KeyCodeMapping` — pure, unit-tested input mapping.
  - `SimulatorPreviewProbe` — dev-only executable to verify the private path on a
    machine; **never shipped** in the app.
- **AgentHubCore wiring:**
  - `Package.swift` — `.package(path: "../SimulatorPreview")` + product dep.
  - `UI/SimulatorPreviewSidePanelView.swift` — the panel; reuses the existing
    `SimulatorService` for device lifecycle and the module for rendering.
  - `UI/MultiProviderMonitoringPanelView.swift` — `SidePanelContent.simulator`
    case + routing + `onShowSimulatorPreview` callbacks (both card callsites).
  - `UI/MonitoringCardView.swift` — the **Preview** button (gated on
    `isXcodeProject`) and the `onShowSimulatorPreview` callback.
  - `Configuration/AgentHubProvider.swift` — `simulatorStreamService` property.

The stream renders inside device chrome (`SimulatorDeviceChromeView`): the
screen is clipped to the device's continuous corner radius and floated in a
dark bezel ring with a shadow on a dark stage. The radius is the device's real
`_displayCornerRadius` looked up by CoreSimulator device type
(`SimulatorDisplayMetrics`, e.g. iPhone 17 Pro = 62 pt @3x); unknown devices
fall back to an aspect-ratio heuristic (edge-to-edge iPhone ≈13.5% of width,
16:9 square, iPad slight). CoreSimulator's device profiles don't expose the
radius — only a chrome-artwork id — hence the curated table. A floating dark
pill (`SimulatorDeviceToolbarView`) hovers above the device with the device
name + OS version and the device-level actions (Home, Annotate toggle, element
refresh); the panel header keeps only panel-level controls (mode switch,
hot-reload status, device picker, close). Build/run and shutdown live as
floating circular actions at the preview stage's top-right corner. The chrome
sizes the content to the framebuffer's exact aspect, so input/annotation mapping
inside it needs no letterbox handling. The toolbar Home button injects `.home` for ~16:9
devices and `.swipeHome` for edge-to-edge ones.

This complements the **existing** `SimulatorService` + `SimulatorPickerView`
(device list / boot / build & run / open Simulator.app), which predate this feature
and are unchanged. The new module only adds capture + input + the in-app view.

## Backends & graceful degradation

`SimulatorStreamAvailability.probe(...)` checks for both private frameworks on disk:

- **`coreSimulator`** (default): taps the simulator framebuffer **IOSurface**
  (zero-copy, native fps) and injects Indigo HID touch/keyboard/button events.
  No TCC permissions.
- **`screenshotPolling`** (fallback): public `simctl io screenshot`, ~2 fps,
  view-only. Used when the private frameworks are absent, or when the
  `coreSimulator` path throws at runtime (e.g. Apple renames a selector). The panel
  shows a **"View-only"** badge in that mode.

All private access is reflective and guarded, so a missing/renamed symbol falls
back rather than crashing.

**Self-healing:** the capture path has no end-of-stream signal — when a device
dies, frame callbacks just stop and the idle re-emit keeps painting the last
frame. `SimulatorStreamSession` therefore runs a liveness watchdog (3s cadence,
cheap in-process `SimDevice.stateString` read, injectable for tests): device
not booted → backend torn down + `.failed(message:)` emitted (the panel
refreshes the device list so the boot/run affordance replaces the frozen
mirror); device booted again with a consumer attached → the backend restarts on
its own. The Previews tab is similarly self-healing: after its fast ~8s
"Starting previews…" window, `SimulatorPreviewSpotlightView` keeps a slow 3s
re-probe alive while the host is expected, so a host that comes back (slow
launch, relaunch) recovers without the manual button.

## Privacy contract (do not regress)

This is the design constraint, not an afterthought:

- **No Screen Recording / Accessibility prompts.** We read only the simulator's own
  framebuffer surface and post events straight to the simulator device — never the
  user's screen, never the window server. This is why we deliberately did **not**
  use ScreenCaptureKit of the Simulator.app window. The annotation inspector reads
  the *simulated app's* accessibility tree over CoreSimulator XPC — it never touches
  host accessibility and triggers no TCC prompt.
- **Nothing leaves the machine; no sockets.** Unlike `serve-sim` (HTTP/MJPEG server
  on `0.0.0.0`, open CORS), all frames stay in-process. No server, no port, no
  network.
- **No persistence while streaming.** Frames are enqueued to the display layer and
  dropped; nothing is written to disk. (The probe's PNG dump is a dev-only target.)
  The one exception is explicit and user-initiated: sending annotations writes a
  single pin-stamped screenshot to the app's temp directory so the agent can read
  it — never automatically, never anywhere else.
- Simulator lifecycle stays on public `xcrun simctl` / `xcodebuild`; physical
  device runs use Xcode's public `devicectl` CLI after the device build.

## Private-API risk

`coreSimulator` uses Apple-private frameworks. AgentHub already ships outside the
App Store via Sparkle and is non-sandboxed, so this is acceptable (same surface
`idb` and `serve-sim` accept). Keep the private surface minimal and centralized in
`CoreSimulatorBridge` / `FramebufferCapture` / `HIDInjector`; never spread `dlsym`
calls into the UI layer.

## Verifying

```bash
cd app/modules/SimulatorPreview
swift test                                       # pure-logic unit tests (14)
xcrun simctl boot <udid>; open -a Simulator
swift run SimulatorPreviewProbe <udid> /tmp/f.png   # live private-path check
```

App build: `xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub build`.

## Hot reload + Previews tab

The panel header has a **Live | Previews** toggle (booted devices only) when
SwiftUI simulator previews are enabled in Settings; **Live** remains available
when previews are disabled. The header also has a **● Hot reload** status pill.
Save a Swift file in the project and the running app hot-swaps it in place
(~sub-second, state preserved) while the Previews tab re-renders on the same
signal. Changes injection can't represent (new file, deleted file,
stored-property layout change, compile failure) quietly fall back to an
incremental rebuild — the pill shows "Rebuilding…", never a silent lie.

### How it works

Two support dylibs are inserted into the user's app at launch
(`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, which `simctl launch` forwards):

- **`AgentHubInjection`** — embeds [InjectionLite] (pinned, see
  `HotReloadHostPackage.injectionLiteVersion`), linked `-all_load` so its
  `+load` boot survives. It self-watches `INJECTION_DIRECTORIES` (the project
  + `~/Library`, which covers AgentHub's custom derived-data path), replays
  the per-file swift-frontend command from the build log, and dlopens the
  recompiled dylib. Requires `OTHER_LDFLAGS=-Xlinker -interposable` and
  `EMIT_FRONTEND_COMMAND_LINES=YES`, which `SimulatorService` adds to
  hot-reload builds.
- **`AgentHubPreviewHost`** — our generated preview host built on
  [SnapshotPreviews]'s `SnapshotPreviewsCore` (pinned, see
  `HotReloadHostPackage.snapshotPreviewsVersion`) + FlyingFox, gated on
  `AGENTHUB_PREVIEW_HOST=1`. It serves the same HTTP contract as the stock
  `Snapshotting` dylib (`GET /file` manifest, `GET /display/{type}/{id}`
  render) on loopback port 38824 — note FlyingFox binds the **IPv6** loopback
  (`[::1]`), which the client targets first — but renders with the windowless
  `SwiftUIRenderingStrategy`. **Never insert the stock `Snapshotting` dylib
  next to the live mirror:** its `UIKitRenderingStrategy` covers the running
  app with a full-screen system-background window the moment it activates
  (the "blank simulator" failure), and its `+load` force-enables AX
  automation. The simulator shares the host's loopback and filesystem, so
  AgentHub reads the manifest and rendered PNGs directly.

Both dylibs link a C constructor that line-buffers stdout: `simctl launch
--stdout=<file>` redirects to a file, which libc fully buffers — without it
the injection engine's log lines (our reload-confirmation signal) sit
unflushed for kilobytes.

Injection-armed builds use a **separate derived-data path** (`…-hotreload`
suffix in `SimulatorService`). The engine replays per-file swift-frontend
commands from the freshest `.xcactivitylog` it can find; those commands only
exist for files actually compiled with `EMIT_FRONTEND_COMMAND_LINES`, and an
incremental build over a plain cache recompiles nothing (observed failure:
the engine then latched onto a *different project's* newer log). The first
armed build is therefore a full compile, once; after that it's incremental.

Both are built once on first use by `HotReloadArtifactStore` (actor): it
materializes a generated wrapper package (`HotReloadHostPackage`, exact-pinned
upstream deps) under `~/Library/Application Support/AgentHub/HotReloadHost/`
and runs `xcodebuild -destination "generic/platform=iOS Simulator"` on it. The
first build resolves from the network and takes a minute or two — the pill
reports "preparing" and that run launches plain; the next Build & Run arms.
Artifacts are cached until `HotReloadHostPackage.fingerprint` changes.
`DYLD_FRAMEWORK_PATH` covers the dependent dynamic `PreviewsSupport.framework`.

Hot-reload launches use `simctl launch --terminate-running-process
--stdout=<log>` — never `--console-pty` (simctl forwards signals, so a console
process would kill the user's app when AgentHub stops it). The log is tailed
host-side (`HotReloadConsoleTail`, kqueue + byte offsets) and
`HotReloadConsoleParser` turns InjectionLite's `🔥` lines into events:
`✅ Hot reload complete` → injected, `❌ Compilation failed` / `⚠️ Could not
locate command` / type-size-changed → rebuild fallback.

Pipeline: `HotReloadSourceWatcher` (host-side FSEvents; existence-snapshot
classifier so atomic-save renames aren't mistaken for structural changes) and
the console events feed `HotReloadMonitor` (the pill's state machine; its
`reloadGeneration` re-renders the visible previews, and its
`changedSourceFiles` selects it). Preview candidate observation is controlled
by the Settings toggle: when disabled, the Previews tab is hidden, preview
candidate tracking is stopped, and future panel launches omit the preview-host
dylib. Live simulator streaming remains available.

The Previews tab (`SimulatorPreviewSpotlightView`) is deliberately bounded:
it shows the open Swift file first, then recent changed files, deduplicated
and capped. One matching preview renders as a large spotlight; several matches
render as a small grid, and the user can expand any preview so it stays pinned
until minimized. The tab is **self-healing and self-starting**: previews live
inside the app's process (they follow the armed process, not the device picker).
Switching to the tab — or opening a Swift file while on it — auto-runs the
play flow when there's something to show: a cold device gets a full
Build & Run (boot is always implicit in play; there is no boot-only button),
a running-but-unarmed app gets the ~1s relaunch via
`SimulatorService.relaunchWithHotReload` (no rebuild; armed derived data
preferred, plain as fallback). The unavailable state keeps manual
"Launch Previews" recovery for the cases auto-arm skips (nothing to show yet,
prior build failure), while the parent chooses the fast relaunch or full build
path. After an armed launch, transient host connection failures render as a
bounded "Starting previews…" state instead of a stale "not running" error. Both panel surfaces stay mounted
across Live ↔ Previews switches so the stream never visibly reconnects.
Discovery fetches metadata only (a runtime symbol scan; fine at monorepo
scale), and visible renders are capped so the live app's main thread is not
overloaded. Rendering also pauses while a reload/rebuild is in flight so it
can't race the code swap. File↔preview matching: `#Preview`
registries match exactly via the fileID in their manifest display name;
`PreviewProvider` types match by the `Foo_Previews` ↔ `Foo.swift` convention
(`matchesSource(fileNames:)`, unit-tested). `SimulatorHotReloadController`
(AgentHubCore) glues monitor + watcher + tail + `PreviewHostHTTPClient` and
triggers the fallback rebuild through `SimulatorService.buildAndRunOnSimulator
(udid:projectPath:hotReload:)`.

For SwiftUI body re-rendering after injection the user's app should add the
[Inject](https://github.com/krzysztofzablocki/Inject) package (or InjectionLite
conventions like `@objc func injected()`); without it, injected code is live
but views may not visibly refresh until state changes. This is the documented
per-project opt-in.

[InjectionLite]: https://github.com/johnno1962/InjectionLite
[SnapshotPreviews]: https://github.com/getsentry/SnapshotPreviews

### Invariants (do not regress)

- The pill is honest: `.reloaded` only on engine confirmation, `.rebuilding`
  on every fallback, `.unavailable(reason)` when machinery couldn't arm.
- Pins are exact; `HotReloadConsoleParser` and the launch-env contract are
  written against the pinned versions — bump them together
  (`HotReloadHostPackage`) and re-verify the parser strings.
- Nothing is ever written into the user's repo: build-setting overrides are
  command-line-only, support artifacts live in Application Support.
- Loopback only (the generated host listens on port 38824; the client tries
  `[::1]` first, then `127.0.0.1`); one preview host can run at a time — a
  second session's Previews tab shows the unreachable state rather than
  fighting over the port.
- Everything testable is pure and tested in `SimulatorPreviewTests`
  (`swift test` in the module: env contract, parser, classifier, locator,
  monitor transitions, manifest/render decoding, tail).

## Agent-driven runs & the verification loop (MCP)

AgentHub does **not** expose bundled simulator-control MCP tools. For Xcode
project launches, AgentHub instead bootstraps the external
[XcodeBuildMCP](https://www.xcodebuildmcp.com/) server into both Claude and
Codex sessions. The bootstrap is generated in `CLICommandConfiguration` and
attached by `EmbeddedTerminalLaunchBuilder` only when all three hold:

- the launch directory is an Xcode project;
- **Agent simulator tools (XcodeBuildMCP)** is on (Settings → iOS Simulator,
  default on, `AgentHubDefaults.xcodeBuildMCPEnabled`);
- `XcodeBuildMCPPreflight` finds a way to actually run the server: a global
  `xcodebuildmcp` binary, `npx` on the search path, or an nvm-managed Node
  install.

Nothing needs preinstalling: the server launch script prefers a global
`xcodebuildmcp` binary and otherwise fetches the **pinned** release via
`npx` (`XcodeBuildMCPBootstrap.pinnedNPMVersion` — never `@latest`, so
sessions don't drift with npm's latest tag). When the preflight fails (no
Node at all), the session still launches — just without the bootstrap and
without the guidance prompt below — and `XcodeBuildMCPNodeNotice` posts a
one-time notification suggesting a Node.js install; the Settings toggle also
shows an inline warning.

The XcodeBuildMCP config includes:

- `XCODEBUILDMCP_CWD`: the AgentHub launch path, so project-local
  `.xcodebuildmcp/config.yaml` and relative paths resolve from the same place
  as the terminal session.
- `XCODEBUILDMCP_WORKSPACE_PATH` or `XCODEBUILDMCP_PROJECT_PATH`: the detected
  `.xcworkspace` (preferred) or `.xcodeproj`, including one subdirectory deep
  for common monorepos.
- `XCODEBUILDMCP_SIMULATOR_ID`: the saved AgentHub run destination for that
  project when it is a simulator.
- `XCODEBUILDMCP_ENABLED_WORKFLOWS=simulator,ui-automation`, plus telemetry
  opt-out through `XCODEBUILDMCP_SENTRY_DISABLED=true`.

`SimulatorAgentGuidance.systemPrompt` is injected whenever the bootstrap is
attached (never without it — guidance pointing at tools that can't connect
misleads agents): Claude receives it via `--append-system-prompt`; Codex
receives it via the `developer_instructions` config override. The guidance
tells agents to inspect XcodeBuildMCP session defaults before the first
build (setting missing project/scheme/simulator context with its discovery
tools) and to **scale verification to the change and the user's intent**:
compile check for refactors and non-visual changes; build/run when runtime
behavior changes; the full UI-automation + screenshot/inspection loop only
when the user asked for visual/end-to-end verification or a specific visual
result is being claimed. The full loop is deliberately not the default — it
is slow and token-expensive, and the depth decision is the model's. The
annotation prompt footer still asks for live-simulator verification when a
user sends pins from the simulator: pins are explicit visual intent.

Manual recording remains an AgentHub side-panel feature only. The record button
uses `SimulatorRecordingService` from the app UI and there is intentionally no
agent-facing recording tool in AgentHub's MCP server.

The recording audit flow assumes the agent **cannot decode video**: after a
recording stops and validates, `SimulatorRecordingFrameSampler` (AVFoundation,
no ffmpeg dependency) extracts up to 10 evenly spaced JPEG frames into a
sibling `<recording>-frames/` directory, and the audit prompt lists those frame
paths as directly readable images — ffmpeg/ffprobe is mentioned only as an
optional finer-timing tool. Deleting a recording
(`SimulatorRecordingService.deleteRecordingFile`) also removes its frames
directory. A recording whose MP4 validates as finalized stays usable even if
the recorder process needed a forced stop; only an unfinalized file or a
recorder that never exited fails the recording. Sending the audit dismisses the
composer and shows a transient "Sent to agent" pill — the MP4 and frames stay
on disk because the agent reads them from the prompt paths.

## Auto Build & Run on code changes

Settings → iOS Simulator → **Auto Build & Run on code changes** (default on,
`AgentHubDefaults.simulatorAutoRunOnAgentChanges`). While a Simulator panel is
open with a simulator destination and the running app is **not**
injection-armed, any Swift source change (agent or human) debounces (2s) into
the panel's own Build & Run flow — `SimulatorHotReloadController` observes the
same `HotReloadSourceWatcher` stream and calls `onRequestAutoRun`; a busy
build retries instead of dropping the change. Once a launch **is** armed,
injection hot-swaps saves and the structural-rebuild fallback covers
created/deleted files, so auto-run stays out of the way. Physical-device
destinations never auto-run.

## Hiding the real Simulator.app while mirroring

The panel is the display, so showing the real Simulator window next to it is
duplicate noise. Settings → iOS Simulator → **Hide Simulator.app while
mirroring** (default on, `AgentHubDefaults.simulatorHideSimulatorAppWhileMirroring`):

- Panel-mirrored launches pass `foregroundSimulatorApp: false` through
  `buildAndRunOnSimulator` (threaded down to `installAndLaunch`), so the
  post-launch `open -a Simulator` is skipped. A non-panel build/run still
  foregrounds by default — with no mirror, the real window is the only place
  the user can see the app. The controller's default rebuild
  executor (structural-change rebuilds) respects the setting too.
- `SimulatorAppHider` ⌘H-hides an already-running Simulator.app
  (`NSRunningApplication.hide()` — public API, no TCC, never terminates;
  the device and capture keep running because rendering lives in the
  CoreSimulator daemons, not the window). The panel hides on live-stream
  activation and after panel-flow runs — never on a timer, so a user who
  deliberately unhides it isn't fought. The picker's explicit "Open
  Simulator.app" action activates (and thus unhides) it.

## Known gaps / future work

- Element data comes from the accessibility tree: role, label, identifier,
  value, frame. Fonts/colors are not in AX (the Codex demo showing CSS fonts was
  inspecting a React Native app's own DOM layer — not generically possible for
  native apps).
- The AX tree is a snapshot — it refreshes on annotate-enable and via the
  refresh button, not live on every app mutation.
- No pinch/rotate/orientation or Digital Crown yet (serve-sim has the primitives;
  `HIDInjector` is trimmed to single-touch + keyboard + Home/Lock/AppSwitcher).
  Rotation's transport is known (serve-sim/idb: GSEvent mach message, type 50 |
  0x20000, to the device's `PurpleWorkspacePort` via `-[SimDevice lookup:error:]`),
  but shipping it also requires counter-rotated rendering plus input/annotation
  coordinate remapping — the framebuffer stays portrait while content rotates.
- Scroll-wheel → drag and trackpad gestures are not mapped.
- Hot reload: the Previews tab renders the *current* in-process previews —
  newly added `#Preview`s appear only after the structural-change rebuild.
  Injection success is engine-confirmed, but SwiftUI visual refresh depends
  on the app adopting Inject/`injected()` (see above). Per-device preview
  hosts (port-per-session) and a zero-opt-in SwiftUI refresh are future work.
- Hot reload does not yet detect simulator app crashes, so the pill can stay
  stale until the next panel action. The `...-hotreload` derived-data path is
  a separate build cache, and console logs under Application Support do not
  have a cleanup policy yet.
- Auto Build & Run is panel-scoped: with the Simulator panel closed there is
  no source watcher, so hands-free relaunch relies on the agent using
  XcodeBuildMCP build/run after its edits. An app-wide watcher for Xcode
  projects with saved destinations is future work.
