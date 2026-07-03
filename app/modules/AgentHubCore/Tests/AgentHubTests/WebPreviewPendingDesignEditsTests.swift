import Canvas
import Foundation
import Testing

@testable import AgentHubCore

private func makeElement(textContent: String = "Launch") -> ElementInspectorData {
  ElementInspectorData(
    tagName: "BUTTON",
    elementId: "",
    className: "cta",
    textContent: textContent,
    outerHTML: "<button class=\"cta\">\(textContent)</button>",
    cssSelector: ".cta",
    computedStyles: [:],
    boundingRect: .zero,
    parentTagName: "",
    parentStyles: [:],
    children: ElementRelationships(),
    siblings: ElementRelationships()
  )
}

@Suite("WebPreviewPendingDesignEditBatch")
struct WebPreviewPendingDesignEditsTests {

  @Test("Repeated edits to the same property collapse last-wins and keep the first old value")
  func repeatedStyleEditsCollapseLastWins() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())

    batch.recordStyleChange(property: "font-size", oldValue: "16px", newValue: "18px")
    batch.recordStyleChange(property: "font-size", oldValue: "18px", newValue: "22px")

    #expect(batch.styleChanges == [
      WebPreviewPendingStyleChange(property: "font-size", oldValue: "16px", newValue: "22px")
    ])
    #expect(batch.changeCount == 1)
  }

  @Test("Reverting to the first-seen value cancels the pending change")
  func revertingToOriginalValueCancelsChange() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())

    batch.recordStyleChange(property: "color", oldValue: "red", newValue: "green")
    batch.recordStyleChange(property: "color", oldValue: "green", newValue: "red")

    #expect(batch.isEmpty)
  }

  @Test("Recording a no-op style change is ignored")
  func noOpStyleChangeIsIgnored() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())

    batch.recordStyleChange(property: "color", oldValue: "red", newValue: "red")

    #expect(batch.isEmpty)
  }

  @Test("Distinct properties are recorded in order")
  func distinctPropertiesAccumulateInOrder() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())

    batch.recordStyleChange(property: "margin", oldValue: "8px", newValue: "12px")
    batch.recordStyleChange(property: "padding", oldValue: nil, newValue: "16px")

    #expect(batch.styleChanges.map(\.property) == ["margin", "padding"])
    #expect(batch.changeCount == 2)
  }

  @Test("Text changes keep the original old text across repeated edits")
  func textChangesKeepOriginalOldText() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())

    batch.recordTextChange(oldText: "Launch", newText: "Buy now")
    batch.recordTextChange(oldText: "Buy now", newText: "Get started")

    #expect(batch.textChange == WebPreviewPendingTextChange(oldText: "Launch", newText: "Get started"))
    #expect(batch.changeCount == 1)
  }

  @Test("Reverting text to the original cancels the pending text change")
  func revertingTextCancelsChange() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())

    batch.recordTextChange(oldText: "Launch", newText: "Buy now")
    batch.recordTextChange(oldText: "Buy now", newText: "Launch")

    #expect(batch.textChange == nil)
    #expect(batch.isEmpty)
  }

  @Test("Removing a style change deletes only that property")
  func removeStyleChangeDeletesProperty() {
    var batch = WebPreviewPendingDesignEditBatch(element: makeElement())

    batch.recordStyleChange(property: "margin", oldValue: "8px", newValue: "12px")
    batch.recordStyleChange(property: "padding", oldValue: "4px", newValue: "16px")
    batch.removeStyleChange(property: "margin")

    #expect(batch.styleChanges.map(\.property) == ["padding"])
  }
}
