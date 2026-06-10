# Simulator Preview (live in-app iOS Simulator)

Read this before editing the live simulator preview: the `SimulatorPreview`
module, `SimulatorPreviewSidePanelView`, the `.simulator` side-panel case, the
`onShowSimulatorPreview` card callback, or `AgentHubProvider.simulatorStreamService`.

## What it is

Renders a **live, interactive iOS Simulator inside AgentHub's side panel** — the
same capability Codex shipped via its "Build iOS Apps" plugin (which used
`serve-sim` + `SnapshotPreviews`), but native, in-process, and private by default.

The user clicks **Simulator** (shown only for Xcode projects). The side panel lets
them pick/boot a device and Build & Run, then mirrors the device's screen and
forwards mouse/keyboard back to it. The old per-card Simulator button that opened
the `SimulatorPickerView` sheet is deprecated: the panel is now the single entry
point, and the full management sheet (Mac runs, build-error forwarding) is
reachable from the panel header's manage button. (The legacy `MonitoringPanelView`
path, which doesn't wire the side-panel callback, still falls back to the sheet.)

## Annotation feedback (element-aware pins sent to the agent)

The header's **Annotate** toggle pauses touch forwarding and reads the frontmost
app's **accessibility tree** (`SimulatorAXInspector`): element frames render over
the mirrored screen, hovering highlights the element under the cursor with a
role/size chip, and clicks drop numbered pins **bound to that element** — an
inline bubble captures the instruction ("move this to be top aligned"). Queued
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
unit-tested).

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
refresh); the panel header keeps only panel-level controls (device picker,
build & run, manage, close). The chrome sizes the
content to the framebuffer's exact aspect, so input/annotation mapping inside it
needs no letterbox handling. A header Home button injects `.home` for ~16:9
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
- Device lifecycle stays on public `xcrun simctl` / `xcodebuild`.

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
- No SwiftUI Preview gallery / hot reload (Codex's `SnapshotPreviews` +
  dlopen-dylib-swap path). That's a separate, larger layer and intentionally out of
  scope for v1.
- Scroll-wheel → drag and trackpad gestures are not mapped.
