import Canvas
import Testing

@testable import AgentHubCore

@Suite("WebPreviewContextQueue")
struct WebPreviewContextQueueTests {

  @Test("Accumulates selections in order")
  func accumulatesSelections() {
    var queue = WebPreviewContextQueue()

    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")

    queue.append(first)
    queue.append(second)

    #expect(queue.elements == [first, second])
    #expect(queue.count == 2)
  }

  @Test("Removes a single queued selection by id")
  func removesSelectionByID() {
    var queue = WebPreviewContextQueue()

    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")
    queue.append(first)
    queue.append(second)

    queue.remove(id: first.id)

    #expect(queue.elements == [second])
  }

  @Test("Clears all queued selections")
  func clearsSelections() {
    var queue = WebPreviewContextQueue()

    queue.append(makeElement(tagName: "BUTTON", selector: ".hero button"))
    queue.append(makeElement(tagName: "DIV", selector: ".pricing-card"))

    queue.clear()

    #expect(queue.isEmpty)
    #expect(queue.elements.isEmpty)
  }

  @Test("Composes a multi-element context prompt")
  func composesContextPrompt() {
    var queue = WebPreviewContextQueue()
    queue.append(makeElement(
      tagName: "BUTTON",
      selector: ".hero button",
      outerHTML: "<button>Launch</button>",
      computedStyles: ["color": "#fff"]
    ))
    queue.append(makeElement(
      tagName: "SECTION",
      selector: ".pricing",
      outerHTML: "<section class=\"pricing\"></section>",
      computedStyles: ["backgroundColor": "#111"]
    ))

    let prompt = queue.composedContextPrompt()

    #expect(prompt?.contains("### Element 1") == true)
    #expect(prompt?.contains("### Element 2") == true)
    #expect(prompt?.contains(".hero button") == true)
    #expect(prompt?.contains(".pricing") == true)
    #expect(prompt?.contains("User request") == false)
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
