# SimulatorPreview

Renders a **live, interactive iOS Simulator** inside AgentHub — the same capability
Codex shipped via its "Build iOS Apps" plugin, but native and in-process.

This is a standalone Swift package (like `Storybook`) so the private-framework
capture code is fully isolated from `AgentHubCore`. AgentHubCore depends on it as a
local package and exposes it through a side panel.

## What it does

- Streams a booted simulator's display into an `AVSampleBufferDisplayLayer` at the
  framebuffer's native rate.
- Forwards mouse → touch (incl. drag), keyboard, and hardware buttons back to the
  device so the preview is interactive.
- Reuses AgentHub's existing `SimulatorService` for the lifecycle (list devices,
  boot, build & run); this module only adds capture + input + rendering.

## Backends

| Backend | Mechanism | FPS | Interactive | Permissions |
|---|---|---|---|---|
| `coreSimulator` (default) | dlopen private `CoreSimulator` + `SimulatorKit`, tap the framebuffer **IOSurface** (zero-copy), inject Indigo HID events | native (~60) | yes | **none** |
| `screenshotPolling` (fallback) | public `xcrun simctl io <udid> screenshot` | ~2 | no (view-only) | none |

`SimulatorStreamAvailability.probe(...)` checks for both private frameworks on disk
and picks the backend. If the private path is present but fails at runtime (e.g.
Apple renamed a selector in a future Xcode), the session degrades to screenshot
polling automatically — it never crashes the app.

## Privacy & safety

This is the design constraint that shaped the module:

- **No Screen Recording / Accessibility TCC prompts.** We read only the simulator's
  own framebuffer surface and post events straight to the simulator device — never
  the user's screen, never the window server. (This is the key reason we did *not*
  use ScreenCaptureKit of the Simulator.app window.)
- **Nothing leaves the machine and nothing opens a socket.** Unlike serve-sim, which
  runs an HTTP/MJPEG server bound to `0.0.0.0` with open CORS, this module keeps all
  frames in-process. There is no server, no port, no network.
- **No persistence of frame data.** Frames are handed to the display layer and
  dropped; nothing is written to disk (the `SimulatorPreviewProbe` PNG dump is a
  dev-only target, never built into the app).
- All device lifecycle stays on **public `xcrun simctl`** tooling.

## Private API risk

`coreSimulator` uses Apple-private frameworks (`CoreSimulator`, `SimulatorKit`).
AgentHub already ships outside the App Store via Sparkle and is non-sandboxed, so
this is acceptable — it's the same surface `idb` and serve-sim accept. All access is
reflective (`NSClassFromString` / `dlsym`) and guarded, so a missing/renamed symbol
falls back rather than crashing. Keep the surface minimal and centralized in
`CoreSimulatorBridge`, `FramebufferCapture`, and `HIDInjector`.

## Verifying locally

```bash
cd app/modules/SimulatorPreview
swift test                                   # pure-logic unit tests
# live check against a booted sim (dev-only target):
xcrun simctl boot <udid>; open -a Simulator
swift run SimulatorPreviewProbe <udid> /tmp/frame.png
```

## Attribution

The framebuffer-capture and HID-injection techniques (`FramebufferCapture.swift`,
`HIDInjector.swift`, `CoreSimulatorBridge.swift`) are adapted from
[EvanBacon/serve-sim](https://github.com/EvanBacon/serve-sim), Apache License 2.0.
We use the same CoreSimulator/SimulatorKit reflection but render in-process and drop
serve-sim's HTTP server, H.264 encoder, and `0.0.0.0` networking entirely.
