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
    #expect(prompt?.contains("crop.png") == true)
  }

  @Test("Returns nil for an empty queue")
  func rejectsEmptyQueue() {
    let emptyQueue = WebPreviewContextQueue()
    #expect(emptyQueue.composedContextPrompt() == nil)

    var queue = WebPreviewContextQueue()
    queue.append(makeElement(tagName: "BUTTON", selector: ".hero button"))
    #expect(queue.composedContextPrompt() != nil)
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
