import Canvas
import Testing

@testable import AgentHubCore

@Suite("QueuedWebPreviewContextStore")
struct QueuedWebPreviewContextStoreTests {

  @Test("Queues are isolated by session")
  func isolatesQueuesBySession() {
    var store = QueuedWebPreviewContextStore()
    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")

    store.append(first, for: "session-a")
    store.append(second, for: "session-b")

    #expect(store.queue(for: "session-a").elements == [first])
    #expect(store.queue(for: "session-b").elements == [second])
  }

  @Test("Removing one element keeps the remaining queue")
  func removesSingleElement() {
    var store = QueuedWebPreviewContextStore()
    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")

    store.append(first, for: "session-a")
    store.append(second, for: "session-a")
    store.remove(elementID: first.id, for: "session-a")

    #expect(store.queue(for: "session-a").elements == [second])
    #expect(store.count(for: "session-a") == 1)
  }

  @Test("Consuming a prompt clears that session queue")
  func consumesPromptAndClearsQueue() {
    var store = QueuedWebPreviewContextStore()
    store.append(makeElement(tagName: "BUTTON", selector: ".hero button"), for: "session-a")
    store.append(makeElement(tagName: "DIV", selector: ".pricing-card"), for: "session-a")

    let prompt = store.consumeContextPrompt(for: "session-a")

    #expect(prompt?.contains("Selected web element context:") == true)
    #expect(prompt?.contains("### Element 1") == true)
    #expect(store.count(for: "session-a") == 0)
    #expect(store.queue(for: "session-a").isEmpty)
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
