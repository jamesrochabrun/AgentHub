import AgentHubCLIKit
import Canvas
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("StudioDesignEditState")
struct StudioDesignEditStateTests {
  private func element(_ selector: String, text: String = "Go", color: String = "rgb(0, 0, 0)") -> ElementInspectorData {
    ElementInspectorData(
      tagName: "BUTTON", elementId: "", className: "btn", textContent: text,
      outerHTML: "<button class=\"btn\">\(text)</button>", cssSelector: selector,
      computedStyles: ["color": color, "backgroundColor": "rgb(255, 255, 255)", "fontSize": "16px", "borderRadius": "4px"],
      boundingRect: CGRect(x: 0, y: 0, width: 80, height: 32)
    )
  }

  @Test("Edits batch per element with old→new deltas, in selection order, stamped with variant")
  func batchesPerElement() {
    let state = StudioDesignEditState()
    let a = element(".studio-artboard[data-variant=\"ghost\"] > button")
    let b = element(".studio-artboard[data-variant=\"solid\"] > button", text: "Buy")

    state.select(a, variantName: "ghost")
    state.apply(DesignEdit(element: a, action: .updateProperty(.color, value: "#fff")), in: nil)
    state.apply(DesignEdit(element: a, action: .updateProperty(.borderRadius, value: "12px")), in: nil)
    state.apply(DesignEdit(element: a, action: .updateProperty(.color, value: "#eee")), in: nil)  // last wins, one entry
    state.apply(DesignEdit(element: a, action: .updateTextContent("Continue")), in: nil)

    state.select(b, variantName: "solid")
    state.apply(DesignEdit(element: b, action: .fitContent), in: nil)
    // Edits for an element that is not selected are ignored.
    state.apply(DesignEdit(element: a, action: .updateProperty(.padding, value: "0")), in: nil)

    #expect(state.pendingChangeCount == 4)
    let ordered = state.orderedEdits
    #expect(ordered.count == 2)
    #expect(ordered[0].variantName == "ghost")
    #expect(ordered[0].batch.styleChanges.map(\.property) == ["color", "border-radius"])
    #expect(ordered[0].batch.styleChanges[0].oldValue == "rgb(0, 0, 0)")
    #expect(ordered[0].batch.styleChanges[0].newValue == "#eee")
    #expect(ordered[0].batch.styleChanges[1].oldValue == "4px")
    #expect(ordered[0].batch.textChange?.oldText == "Go")
    #expect(ordered[0].batch.textChange?.newText == "Continue")
    #expect(ordered[1].variantName == "solid")
    #expect(ordered[1].fitToContent)
    #expect(state.toolbarValues?.textContent == "Buy")  // toolbar seeds from the selected element
  }

  @Test("Reverting to the original value cancels the pending change; delete deselects")
  func revertAndDelete() {
    let state = StudioDesignEditState()
    let a = element("#a")
    state.select(a, variantName: nil)
    state.apply(DesignEdit(element: a, action: .updateProperty(.color, value: "#fff")), in: nil)
    #expect(state.hasPendingEdits)
    state.apply(DesignEdit(element: a, action: .updateProperty(.color, value: "rgb(0, 0, 0)")), in: nil)
    #expect(!state.hasPendingEdits)

    state.apply(DesignEdit(element: a, action: .deleteElement), in: nil)
    #expect(state.selectedElement == nil)
    #expect(state.orderedEdits.first?.deleted == true)
    #expect(state.pendingChangeCount == 1)

    state.clear()
    #expect(!state.hasPendingEdits)
    #expect(state.orderedEdits.isEmpty)
  }

  @Test("Refresh keeps edited toolbar values and adopts the rest; a variant is stamped late without losing the batch")
  func refreshKeepsEditedValues() {
    let state = StudioDesignEditState()
    let a = element("#a", color: "rgb(0, 0, 0)")
    state.select(a, variantName: nil)
    state.apply(DesignEdit(element: a, action: .updateProperty(.color, value: "#123456")), in: nil)
    #expect(state.toolbarValues?.color == "#123456")

    // The page echoes back normalized values plus a changed font size.
    var refreshedStyles = a.computedStyles
    refreshedStyles["color"] = "rgb(18, 52, 86)"
    refreshedStyles["fontSize"] = "18px"
    let refreshed = ElementInspectorData(
      id: a.id, tagName: a.tagName, elementId: a.elementId, className: a.className, textContent: a.textContent,
      outerHTML: a.outerHTML, cssSelector: a.cssSelector, computedStyles: refreshedStyles, boundingRect: a.boundingRect
    )
    state.refresh(with: refreshed)
    #expect(state.toolbarValues?.color == "#123456")
    #expect(state.toolbarValues?.fontSize == 18)

    state.select(refreshed, variantName: "ghost")
    #expect(state.orderedEdits.first?.variantName == "ghost")
    #expect(state.orderedEdits.first?.batch.styleChanges.count == 1)
  }

  @Test("Computed values map kebab properties to the bridge's camelCase keys")
  func computedValueLookup() {
    let a = element("#a")
    #expect(StudioDesignEditState.computedValue(for: .backgroundColor, in: a) == "rgb(255, 255, 255)")
    #expect(StudioDesignEditState.computedValue(for: .borderRadius, in: a) == "4px")
    #expect(StudioDesignEditState.computedValue(for: .letterSpacing, in: a) == nil)
  }
}
