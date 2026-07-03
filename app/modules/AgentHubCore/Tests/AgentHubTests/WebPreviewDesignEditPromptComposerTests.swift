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

  @Test("The instruction directs idiomatic, minimal application")
  func instructionDirectsIdiomaticApplication() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())
    batch.recordStyleChange(property: "color", oldValue: nil, newValue: "blue")

    let instruction = WebPreviewDesignEditPromptComposer.instruction(for: batch)

    #expect(instruction?.contains("match what the code already uses") == true)
    #expect(instruction?.contains("Change only what is needed") == true)
  }
}
