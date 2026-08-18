import Canvas
import Foundation
import Testing

@testable import AgentHubCore

private func makeElement() -> ElementInspectorData {
  ElementInspectorData(
    tagName: "BUTTON",
    elementId: "",
    className: "cta",
    textContent: "Launch",
    outerHTML: "<button class=\"cta\">Launch</button>",
    cssSelector: ".cta",
    computedStyles: [:],
    boundingRect: .zero,
    parentTagName: "",
    parentStyles: [:],
    children: ElementRelationships(),
    siblings: ElementRelationships()
  )
}

@Suite("WebPreviewDesignEditPromptComposer")
struct WebPreviewDesignEditPromptComposerTests {

  @Test("Empty batches produce no instruction")
  func emptyBatchProducesNoInstruction() {
    let batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    #expect(WebPreviewDesignEditPromptComposer.instruction(for: batch) == nil)
  }

  @Test("Style deltas render old and new values")
  func styleDeltasRenderOldAndNewValues() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "line-height", oldValue: "26px", newValue: "30px")
    batch.recordStyleChange(property: "width", oldValue: nil, newValue: "fit-content")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(for: batch)

    #expect(instruction?.contains("- line-height: 26px → 30px") == true)
    #expect(instruction?.contains("- width: fit-content") == true)
  }

  @Test("Text changes render quoted old and new text")
  func textChangesRenderQuoted() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordTextChange(oldText: "Launch", newText: "Buy now")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(for: batch)

    #expect(instruction?.contains("- text content: \"Launch\" → \"Buy now\"") == true)
  }

  @Test("Preview context, source hints, and candidate files are embedded when provided")
  func contextAndHintsAreEmbedded() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "color", oldValue: "red", newValue: "blue")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(
      for: batch,
      previewContext: "dev server at http://localhost:5173",
      candidateFiles: ["src/styles/site.css", "src/App.tsx"],
      sourceHints: ["src/components/Button.svelte:12:4 (svelte)"]
    )

    #expect(instruction?.contains("Preview context: dev server at http://localhost:5173") == true)
    #expect(instruction?.contains("- src/styles/site.css") == true)
    #expect(instruction?.contains("- src/App.tsx") == true)
    #expect(instruction?.contains("unverified hints") == true)
    #expect(instruction?.contains("- src/components/Button.svelte:12:4 (svelte)") == true)
  }

  @Test("Declared sources are listed for edited properties only")
  func declaredSourcesAreEmbeddedForEditedProperties() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "color", oldValue: "rgb(255, 255, 255)", newValue: "blue")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(
      for: batch,
      declaredSources: [
        "color": "declared as `var(--hero-fg)` in rule `.cta` (site.css)",
        "font-size": "declared as `clamp(1rem, 2vw, 2rem)` in rule `.cta` (site.css)",
      ]
    )

    #expect(instruction?.contains("change the declaration in place") == true)
    #expect(instruction?.contains("- color: declared as `var(--hero-fg)` in rule `.cta` (site.css)") == true)
    #expect(instruction?.contains("font-size") == false)
  }

  @Test("A proven file is named even without CSSOM declared values")
  func provenFileIsNamedForEditedProperties() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "color", oldValue: "rgb(0, 0, 0)", newValue: "blue")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(
      for: batch,
      provenFiles: ["color": "styles/site.css"]
    )

    #expect(instruction?.contains("- color: declared in styles/site.css") == true)
  }

  @Test("Declared value and proven file are merged into one line")
  func declaredValueAndProvenFileMerge() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "font-size", oldValue: "18px", newValue: "38px")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(
      for: batch,
      declaredSources: ["font-size": "declared as `clamp(1rem, 2vw, 2rem)` in rule `.hero-sub` (site.css)"],
      provenFiles: ["font-size": "styles/site.css"]
    )

    #expect(
      instruction?.contains(
        "- font-size: declared as `clamp(1rem, 2vw, 2rem)` in rule `.hero-sub` (site.css) — verified in styles/site.css"
      ) == true
    )
  }

  @Test("Batches without declared sources omit the section")
  func declaredSourcesSectionIsOptional() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "color", oldValue: nil, newValue: "blue")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(for: batch)

    #expect(instruction?.contains("Where these values live today") == false)
  }

  @Test("Chip summaries condense the batch to one line")
  func summaryCondensesBatch() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "font-size", oldValue: "18px", newValue: "20px")
    batch.recordStyleChange(property: "color", oldValue: nil, newValue: "blue")
    batch.recordTextChange(oldText: "Launch", newText: "Buy\n  now")

    let summary = WebPreviewDesignEditPromptComposer.summary(for: batch)

    #expect(summary == "font-size 18px → 20px · color blue · text \u{201C}Buy now\u{201D}")
  }

  @Test("Long chip text is clipped")
  func summaryClipsLongText() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordTextChange(oldText: "Launch", newText: String(repeating: "a", count: 90))

    let summary = WebPreviewDesignEditPromptComposer.summary(for: batch) ?? ""

    #expect(summary.contains("…"))
    #expect(summary.count < 90)
  }

  @Test("Empty batches have no chip summary")
  func summaryRejectsEmptyBatch() {
    let batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    #expect(WebPreviewDesignEditPromptComposer.summary(for: batch) == nil)
  }

  @Test("The instruction directs idiomatic, minimal application")
  func instructionDirectsIdiomaticApplication() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "color", oldValue: nil, newValue: "blue")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(for: batch)

    #expect(instruction?.contains("match what the code already uses") == true)
    #expect(instruction?.contains("Change only what is needed") == true)
  }
}
