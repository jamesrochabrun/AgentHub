import Canvas
import CoreGraphics
import Testing

@testable import AgentHubCore

@Suite("QueuedWebPreviewContextStore")
struct QueuedWebPreviewContextStoreTests {

  @Test("Queues are isolated by session")
  func isolatesQueuesBySession() {
    var store = QueuedWebPreviewContextStore()
    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")

    store.append(first, instruction: "Make this larger", for: "session-a")
    store.append(second, instruction: "Increase contrast", for: "session-b")

    #expect(store.queue(for: "session-a").items == [
      WebPreviewQueuedUpdate(element: first, instruction: "Make this larger"),
    ])
    #expect(store.queue(for: "session-b").items == [
      WebPreviewQueuedUpdate(element: second, instruction: "Increase contrast"),
    ])
  }

  @Test("Removing one element keeps the remaining queue")
  func removesSingleElement() {
    var store = QueuedWebPreviewContextStore()
    let first = makeElement(tagName: "BUTTON", selector: ".hero button")
    let second = makeElement(tagName: "DIV", selector: ".pricing-card")

    store.append(first, instruction: "Make this larger", for: "session-a")
    store.append(second, instruction: "Increase contrast", for: "session-a")
    store.remove(elementID: first.id, for: "session-a")

    #expect(store.queue(for: "session-a").items == [
      WebPreviewQueuedUpdate(element: second, instruction: "Increase contrast"),
    ])
    #expect(store.count(for: "session-a") == 1)
  }

  @Test("Consuming a prompt clears that session queue")
  func consumesPromptAndClearsQueue() {
    var store = QueuedWebPreviewContextStore()
    store.append(
      makeElement(tagName: "BUTTON", selector: ".hero button"),
      instruction: "Make this larger",
      for: "session-a"
    )
    store.appendCrop(
      cropRect: CGRect(x: 0, y: 0, width: 300, height: 120),
      elements: [makeElement(tagName: "DIV", selector: ".pricing-card")],
      instruction: "Tighten spacing",
      screenshotPath: nil,
      for: "session-a"
    )

    let prompt = store.consumeContextPrompt(for: "session-a")

    #expect(prompt?.contains("Queued web preview updates:") == true)
    #expect(prompt?.contains("## Update 1: Element") == true)
    #expect(prompt?.contains("## Update 2: Region") == true)
    #expect(store.count(for: "session-a") == 0)
    #expect(store.queue(for: "session-a").isEmpty)
  }

  @Test("Consumed prompt prepends screenshot paths for image attachment")
  func consumedPromptPrependsScreenshotPaths() {
    var store = QueuedWebPreviewContextStore()
    store.appendCrop(
      cropRect: CGRect(x: 0, y: 0, width: 300, height: 120),
      elements: [makeElement(tagName: "DIV", selector: ".card")],
      instruction: "Fix this",
      screenshotPath: "/tmp/crop.png",
      for: "session-a"
    )

    let prompt = store.consumeContextPrompt(for: "session-a")

    #expect(prompt?.hasPrefix("/tmp/crop.png ") == true)
    #expect(prompt?.contains("selected region") == true)
  }

  @Test("Transfers queued updates from pending session to resolved session")
  func transfersQueueFromPendingSession() {
    var store = QueuedWebPreviewContextStore()
    let pendingElement = makeElement(tagName: "BUTTON", selector: ".hero button")
    let pendingCropElement = makeElement(tagName: "SECTION", selector: ".hero")
    let existingResolvedElement = makeElement(tagName: "DIV", selector: ".pricing-card")

    store.append(
      pendingElement,
      instruction: "Make this larger",
      for: "pending-123"
    )
    store.appendCrop(
      cropRect: CGRect(x: 0, y: 0, width: 300, height: 120),
      elements: [pendingCropElement],
      instruction: "Tighten spacing",
      screenshotPath: "/tmp/crop.png",
      for: "pending-123"
    )
    store.append(
      existingResolvedElement,
      instruction: "Increase contrast",
      for: "session-a"
    )

    store.transferQueue(from: "pending-123", to: "session-a")

    #expect(store.count(for: "pending-123") == 0)
    #expect(store.queue(for: "session-a").items.map(\.kindLabel) == [
      "Element",
      "Element",
      "Region",
    ])
    #expect(store.queue(for: "session-a").items.map(\.detail) == [
      "Increase contrast",
      "Make this larger",
      "Tighten spacing",
    ])
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
