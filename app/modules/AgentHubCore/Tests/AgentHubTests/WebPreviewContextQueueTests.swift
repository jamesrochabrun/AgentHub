import Canvas
import CoreGraphics
import Testing

@testable import AgentHubCore

@Suite("WebPreviewContextQueue")
struct WebPreviewContextQueueTests {

  @Test("Accumulates updates in order")
  func accumulatesSelections() {
    var queue = WebPreviewContextQueue()

    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")

    queue.append(first, instruction: "Make this button larger")
    queue.append(second, instruction: "Add more contrast")

    #expect(queue.items == [
      WebPreviewQueuedUpdate(element: first, instruction: "Make this button larger"),
      WebPreviewQueuedUpdate(element: second, instruction: "Add more contrast"),
    ])
    #expect(queue.count == 2)
  }

  @Test("Removes a single queued selection by id")
  func removesSelectionByID() {
    var queue = WebPreviewContextQueue()

    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")
    queue.append(first, instruction: "Make this button larger")
    queue.append(second, instruction: "Add more contrast")

    queue.remove(id: first.id)

    #expect(queue.items == [
      WebPreviewQueuedUpdate(element: second, instruction: "Add more contrast"),
    ])
  }

  @Test("Clears all queued updates")
  func clearsSelections() {
    var queue = WebPreviewContextQueue()

    queue.append(makeElement(tagName: "BUTTON", selector: ".hero button"))
    queue.append(makeElement(tagName: "DIV", selector: ".pricing-card"))

    queue.clear()

    #expect(queue.isEmpty)
    #expect(queue.items.isEmpty)
  }

  @Test("Composes a multi-update prompt")
  func composesBatchUpdatePrompt() {
    var queue = WebPreviewContextQueue()
    queue.append(makeElement(
      tagName: "BUTTON",
      selector: ".hero button",
      outerHTML: "<button>Launch</button>",
      computedStyles: ["color": "#fff"]
    ), instruction: "Make this button larger")
    queue.append(makeElement(
      tagName: "SECTION",
      selector: ".pricing",
      outerHTML: "<section class=\"pricing\"></section>",
      computedStyles: ["backgroundColor": "#111"]
    ), instruction: "Increase contrast")

    let prompt = queue.composedContextPrompt()

    #expect(prompt?.contains("Queued web preview updates:") == true)
    #expect(prompt?.contains("## Update 1: Element") == true)
    #expect(prompt?.contains("## Update 2: Element") == true)
    #expect(prompt?.contains(".hero button") == true)
    #expect(prompt?.contains(".pricing") == true)
    #expect(prompt?.contains("User request: Make this button larger") == true)
    #expect(prompt?.contains("User request: Increase contrast") == true)
  }

  @Test("Composes a queued crop update prompt")
  func composesCropUpdatePrompt() {
    var queue = WebPreviewContextQueue()
    let rect = CGRect(x: 10, y: 20, width: 300, height: 120)

    queue.appendCrop(
      cropRect: rect,
      elements: [makeElement(tagName: "SECTION", selector: ".hero")],
      instruction: "Tighten the spacing",
      screenshotPath: "/tmp/AgentHub/crop-screenshots/crop.png"
    )

    let prompt = queue.composedContextPrompt()

    #expect(prompt?.contains("selected region") == true)
    #expect(prompt?.contains("300") == true)
    #expect(prompt?.contains("120") == true)
    #expect(prompt?.contains("User request: Tighten the spacing") == true)
    // Screenshot paths are excluded from the text prompt and returned
    // via screenshotPaths() for separate handling at send time.
    #expect(prompt?.contains("crop.png") == false)
    #expect(queue.screenshotPaths() == ["/tmp/AgentHub/crop-screenshots/crop.png"])
  }

  @Test("Multi-item composed prompt excludes screenshot path")
  func multiItemPromptExcludesScreenshotPath() {
    var queue = WebPreviewContextQueue()

    queue.append(makeElement(
      tagName: "H1",
      selector: ".title",
      outerHTML: "<h1>Hello</h1>"
    ), instruction: "Make it bigger")

    queue.appendCrop(
      cropRect: CGRect(x: 23, y: 317, width: 298, height: 159),
      elements: [makeElement(tagName: "SPAN", selector: ".arrow")],
      instruction: "What is this?",
      screenshotPath: "/tmp/AgentHub/crop-screenshots/crop-test.png"
    )

    let prompt = queue.composedContextPrompt()

    #expect(prompt != nil)
    #expect(prompt?.contains("## Update 1: Element") == true)
    #expect(prompt?.contains("## Update 2: Region") == true)
    #expect(prompt?.contains("crop-test.png") == false)
    #expect(queue.screenshotPaths() == ["/tmp/AgentHub/crop-screenshots/crop-test.png"])
  }

  @Test("Returns nil for an empty queue")
  func rejectsEmptyQueue() {
    let emptyQueue = WebPreviewContextQueue()
    #expect(emptyQueue.composedContextPrompt() == nil)

    var queue = WebPreviewContextQueue()
    queue.append(makeElement(tagName: "BUTTON", selector: ".hero button"))
    #expect(queue.composedContextPrompt() != nil)
  }

  @Test("Design edits upsert per element instead of piling up chips")
  func designEditsUpsertPerElement() {
    var queue = WebPreviewContextQueue()
    let hero = makeElement(tagName: "H1", selector: ".hero h1")
    let card = makeElement(tagName: "DIV", selector: ".pricing-card")

    queue.upsertDesignEdits(hero, instruction: "font-size: 18px → 20px", detail: "font-size 18px → 20px")
    let firstChipID = queue.items.first?.id
    queue.upsertDesignEdits(card, instruction: "color: red → blue", detail: "color red → blue")

    // A re-capture of the same element carries a new UUID; the chip must be
    // replaced in place rather than duplicated.
    let heroRecaptured = makeElement(tagName: "H1", selector: ".hero h1")
    queue.upsertDesignEdits(
      heroRecaptured,
      instruction: "font-size: 18px → 24px",
      detail: "font-size 18px → 24px"
    )

    #expect(queue.count == 2)
    #expect(queue.items.first?.id == firstChipID)
    #expect(queue.items.first?.detail == "font-size 18px → 24px")
    #expect(queue.items.first?.kindLabel == "Edits")
    #expect(queue.designEditItemID(for: heroRecaptured) == firstChipID)
  }

  @Test("A freeform chip for the same element is left alone by design-edit upserts")
  func designEditsDoNotReplaceFreeformChips() {
    var queue = WebPreviewContextQueue()
    let hero = makeElement(tagName: "H1", selector: ".hero h1")

    queue.append(hero, instruction: "Make this punchier")
    queue.upsertDesignEdits(hero, instruction: "font-size: 18px → 20px")

    #expect(queue.count == 2)
    #expect(queue.items.first?.kindLabel == "Element")
    #expect(queue.items.last?.kindLabel == "Edits")
  }

  @Test("Queued design edits lead the prompt with the project-convention rules")
  func designEditsPrependConventionGuidance() {
    var queue = WebPreviewContextQueue()
    queue.upsertDesignEdits(
      makeElement(tagName: "H1", selector: ".hero h1"),
      instruction: "Apply these design changes to this element:\n- font-size: 18px → 20px"
    )

    let prompt = queue.composedContextPrompt()

    #expect(prompt?.hasPrefix(WebPreviewDesignEditGuidance.preamble) == true)
    #expect(prompt?.contains("Never replace a `var(--token)`") == true)
    #expect(prompt?.contains("- font-size: 18px → 20px") == true)
  }

  @Test("The convention preamble appears once for a mixed queue")
  func conventionGuidanceIsNotRepeated() {
    var queue = WebPreviewContextQueue()
    queue.append(makeElement(tagName: "DIV", selector: ".pricing-card"), instruction: "More contrast")
    queue.upsertDesignEdits(
      makeElement(tagName: "H1", selector: ".hero h1"),
      instruction: "Apply these design changes to this element:\n- color: red → blue"
    )
    queue.upsertDesignEdits(
      makeElement(tagName: "P", selector: ".hero p"),
      instruction: "Apply these design changes to this element:\n- line-height: 26px → 30px"
    )

    let prompt = queue.composedContextPrompt() ?? ""
    let firstRule = "Never replace a `var(--token)`"

    #expect(prompt.hasPrefix(WebPreviewDesignEditGuidance.preamble))
    #expect(prompt.components(separatedBy: firstRule).count - 1 == 1)
    #expect(prompt.contains("## Update 1: Element"))
    #expect(prompt.contains("## Update 3: Edits"))
  }

  @Test("Queues without design edits keep their prompt unchanged")
  func freeformQueuesSkipGuidance() {
    var queue = WebPreviewContextQueue()
    queue.append(makeElement(tagName: "DIV", selector: ".pricing-card"), instruction: "More contrast")

    let prompt = queue.composedContextPrompt() ?? ""

    #expect(!prompt.contains(WebPreviewDesignEditGuidance.preamble))
  }

  private func makeElement(
    tagName: String,
    selector: String,
    outerHTML: String = "",
    computedStyles: [String: String] = [:]
  ) -> ElementInspectorData {
    ElementInspectorData(
      tagName: tagName,
      elementId: "",
      className: "",
      textContent: "",
      outerHTML: outerHTML,
      cssSelector: selector,
      computedStyles: computedStyles,
      boundingRect: .zero
    )
  }
}
