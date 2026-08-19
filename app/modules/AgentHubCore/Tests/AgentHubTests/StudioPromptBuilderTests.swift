import AgentHubCLIKit
import Canvas
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Studio prompt builders")
struct StudioPromptBuilderTests {
  private let element = ElementInspectorData(
    tagName: "BUTTON",
    elementId: "",
    className: "btn",
    textContent: "Go",
    outerHTML: "<button class=\"btn\">Go</button>",
    cssSelector: ".studio-artboard[data-variant=\"ghost\"] > button.btn",
    computedStyles: ["color": "rgb(0, 0, 255)"],
    boundingRect: CGRect(x: 0, y: 0, width: 80, height: 32)
  )

  @Test("Canvas feedback names the variant, carries element context, re-files by id, forbids project edits")
  func canvasFeedback() {
    let prompt = StudioFeedbackPromptBuilder.prompt(
      artifact: makeStudioCanvas(id: "canvas-9"),
      variantName: "ghost",
      element: element,
      instruction: "more padding"
    )
    #expect(prompt.contains("design canvas \"Primary button\""))
    #expect(prompt.contains("agenthub_design (id canvas-9), variant \"ghost\""))
    #expect(prompt.contains("<button class=\"btn\">Go</button>"))
    #expect(prompt.contains("User request: more padding"))
    #expect(prompt.contains("re-file it with agenthub_design using id canvas-9"))
    #expect(prompt.contains("change the \"ghost\" variant, keep the other variants"))
    #expect(prompt.contains("do not edit project files"))
    #expect(!prompt.contains("Implement"))
  }

  @Test("Document feedback uses agenthub_artifact and no variant")
  func documentFeedback() {
    let prompt = StudioFeedbackPromptBuilder.prompt(
      artifact: makeStudioDocument(id: "doc-3"),
      variantName: nil,
      element: nil,
      instruction: "bigger headline"
    )
    #expect(prompt.contains("artifact \"Q3 report\" you rendered with agenthub_artifact (id doc-3)."))
    #expect(!prompt.contains("variant"))
    #expect(prompt.contains("re-file it with agenthub_artifact using id doc-3"))
    #expect(prompt.contains("do not edit project files"))
  }

  @Test("Edit-mode batch prompt lists every element with its variant and deltas, re-files by id, forbids project edits")
  func editsPrompt() throws {
    let prompt = try #require(StudioFeedbackPromptBuilder.editsPrompt(
      artifact: makeStudioCanvas(id: "canvas-9"),
      edits: [
        .init(element: element, variantName: "ghost", changeLines: ["- color: rgb(0, 0, 255) → #fff", "- text content: \"Go\" → \"Continue\""]),
        .init(element: element, variantName: nil, changeLines: ["- remove this element"]),
      ]
    ))
    #expect(prompt.hasPrefix("I made visual edits directly on the Studio design canvas \"Primary button\" (id canvas-9). Please make them permanent."))
    #expect(prompt.contains("### Element 1 — variant \"ghost\""))
    #expect(prompt.contains("### Element 2\n"))
    #expect(prompt.contains("- color: rgb(0, 0, 255) → #fff"))
    #expect(prompt.contains("- remove this element"))
    #expect(prompt.contains("re-file with agenthub_design using id canvas-9".lowercased()) || prompt.contains("Re-file with agenthub_design using id canvas-9"))
    #expect(prompt.contains("do not edit project files"))
    #expect(StudioFeedbackPromptBuilder.editsPrompt(artifact: makeStudioCanvas(), edits: []) == nil)
  }

  @Test("Crop prompt carries region, screenshot path, elements, variant, and re-file framing")
  func cropPrompt() {
    let prompt = StudioFeedbackPromptBuilder.cropPrompt(
      artifact: makeStudioCanvas(id: "canvas-9"),
      variantName: "ghost",
      cropRect: CGRect(x: 10, y: 20, width: 300, height: 120),
      elements: [element],
      instruction: "tighten this group",
      screenshotPath: "/tmp/crop.png"
    )
    #expect(prompt.hasPrefix("I'm looking at a region of the Studio design canvas \"Primary button\" you rendered with agenthub_design (id canvas-9), on variant \"ghost\"."))
    #expect(!prompt.contains("live web preview"))
    #expect(prompt.contains("**Region**: 300px × 120px at (10, 20)"))
    #expect(prompt.contains("/tmp/crop.png"))
    #expect(prompt.contains("**Elements in region** (1)"))
    #expect(prompt.contains("User request: tighten this group"))
    #expect(prompt.contains("re-file it with agenthub_design using id canvas-9"))
    #expect(prompt.contains("do not edit project files"))
  }

  @Test("Promotion sends the original fragment and CSS, names the source path, and never the scoped selector")
  func promotion() throws {
    let prompt = try #require(StudioPromotionPromptBuilder.prompt(artifact: makeStudioCanvas(id: "canvas-9"), variantName: "ghost"))
    #expect(prompt.hasPrefix("Implement the \"ghost\" variant from the Studio design canvas \"Primary button\" (id canvas-9) in the real project, in src/Button.tsx."))
    #expect(prompt.contains("```html\n<button class=\"btn\">Go</button>\n```"))
    #expect(prompt.contains("```css\n.btn { color: blue; }\n```"))
    #expect(!prompt.contains(".studio-artboard"))
    #expect(prompt.contains("Preserve the component's existing behaviour"))
    #expect(prompt.contains("list the files you changed"))
  }

  @Test("Promotion is unavailable for documents and unknown variants")
  func promotionUnavailable() {
    #expect(StudioPromotionPromptBuilder.prompt(artifact: makeStudioDocument(), variantName: "x") == nil)
    #expect(StudioPromotionPromptBuilder.prompt(artifact: makeStudioCanvas(), variantName: "nope") == nil)
  }

  @Test("Promotion without a source path omits the target clause and includes notes")
  func promotionWithoutSourcePath() throws {
    let prompt = try #require(StudioPromotionPromptBuilder.prompt(artifact: makeStudioCanvas(sourcePath: nil), variantName: "solid"))
    #expect(prompt.hasPrefix("Implement the \"solid\" variant from the Studio design canvas \"Primary button\" (id canvas-1) in the real project."))
    #expect(prompt.contains("Design notes: default"))
  }
}
