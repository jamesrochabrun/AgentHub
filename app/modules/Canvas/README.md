# Canvas

A Swift library for inspecting and interacting with web elements in `WKWebView` on macOS. Activate inspect mode, hover to highlight elements, click to capture element data, and send instructions or context to your app.

## Requirements

- macOS 14+
- Swift 6.0+ (Swift tools version)

## Installation

Add Canvas as a dependency in your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/jamesrochabrun/Canvas.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
  name: "YourApp",
  dependencies: [
    .product(name: "Canvas", package: "Canvas")
  ]
)
```

Or in Xcode: **File > Add Package Dependencies** and enter `https://github.com/jamesrochabrun/Canvas.git`.

## Quick Start

```swift
import Canvas
import SwiftUI

struct ContentView: View {

  @State private var inspectState = ElementInspectState()
  @State private var isLoading = false
  @State private var currentURL: URL?

  var body: some View {
    VStack {
      HStack {
        Button("Inspect") {
          inspectState.activate()
        }
      }
      .padding()

      InspectableWebView(
        url: URL(string: "https://example.com")!,
        isFileURL: false,
        isLoading: $isLoading,
        currentURL: $currentURL,
        onElementSelected: { element in
          inspectState.selectElement(element)
        },
        isInspectModeActive: .init(
          get: { inspectState.isActive },
          set: { _ in }
        ),
        selectedElementId: inspectState.selectedElement?.id
      )
      .webInspectorOverlay(state: inspectState) { element, instruction in
        let prompt = ElementInspectorPromptBuilder.buildPrompt(
          element: element,
          instruction: instruction
        )
        // Send prompt to your AI agent, terminal, etc.
        print(prompt)
      }
    }
  }
}
```

## Inspect Modes

Canvas supports two interaction modes.

### Input Mode (default)

The user clicks an element, types an instruction in the floating text editor, and submits. This is the default behavior.

```swift
// Activate input mode
inspectState.activate() // or inspectState.activate(mode: .input)

// Handle submission
.webInspectorOverlay(state: inspectState) { element, instruction in
  let prompt = ElementInspectorPromptBuilder.buildPrompt(
    element: element,
    instruction: instruction
  )
  sendToAgent(prompt)
}
```

### Context Mode

The user clicks an element and its data is sent to the app immediately — no text input required. The inspector stays active so the user can keep clicking elements.

```swift
// Activate context mode
inspectState.activate(mode: .context)

// Handle immediate selection
.webInspectorOverlay(
  state: inspectState,
  onContextSelection: { element in
    let context = ElementInspectorPromptBuilder.buildContextPrompt(
      element: element
    )
    sendToAgent(context)
  }
)
```

## Building Prompts

`ElementInspectorPromptBuilder` produces structured text from captured element data.

**Input mode** — includes the user's instruction:

```swift
let prompt = ElementInspectorPromptBuilder.buildPrompt(
  element: element,
  instruction: "Make this button red"
)
// I'm looking at a web element in the live preview:
//
// **Element**: <button class="btn">Submit</button>
// **CSS Selector**: form > button.btn
// **Computed Styles**:
//   backgroundColor: #007AFF
//   fontSize: 16px
//
// User request: Make this button red
//
// Please modify the source code to make this change.
```

**Context mode** — element context only:

```swift
let context = ElementInspectorPromptBuilder.buildContextPrompt(
  element: element
)
// Selected web element context:
//
// **Element**: <button class="btn">Submit</button>
// **CSS Selector**: form > button.btn
// **Computed Styles**:
//   backgroundColor: #007AFF
//   fontSize: 16px
```

## API Overview

| Type | Description |
|------|-------------|
| `ElementInspectState` | Observable state machine controlling the inspector lifecycle |
| `InspectMode` | `.input` (type instruction) or `.context` (immediate send) |
| `ElementInspectorData` | Immutable snapshot of a captured DOM element |
| `InspectableWebView` | `NSViewRepresentable` wrapping `WKWebView` with inspector support |
| `ElementInspectorBridge` | JavaScript injection and WebKit message handling |
| `ElementInspectorPromptBuilder` | Constructs structured prompts from element data |
| `.webInspectorOverlay()` | View modifier adding the inspector banner and input overlay |

### ElementInspectorData Properties

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Unique identifier |
| `tagName` | `String` | DOM tag name (e.g., `"BUTTON"`) |
| `elementId` | `String` | DOM `id` attribute |
| `className` | `String` | CSS class string |
| `textContent` | `String` | Visible text (truncated ~100 chars) |
| `outerHTML` | `String` | Outer HTML markup (truncated ~500 chars) |
| `cssSelector` | `String` | Computed CSS selector path |
| `computedStyles` | `[String: String]` | Key computed CSS properties |
| `boundingRect` | `CGRect` | Element position and size |

## License

MIT
