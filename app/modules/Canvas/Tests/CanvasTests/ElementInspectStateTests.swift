import CoreGraphics
import Testing
@testable import Canvas

@MainActor
@Suite("ElementInspectState")
struct ElementInspectStateTests {

  // MARK: - Initial State

  @Test func initialStateIsInactive() {
    let state = ElementInspectState()
    #expect(state.isActive == false)
  }

  @Test func initialStateHasNoSelectedElement() {
    let state = ElementInspectState()
    #expect(state.selectedElement == nil)
  }

  @Test func initialStateHasNoViewportRect() {
    let state = ElementInspectState()
    #expect(state.selectedElementViewportRect == nil)
  }

  @Test func initialStateIsInputShowingIsFalse() {
    let state = ElementInspectState()
    #expect(state.isInputShowing == false)
  }

  // MARK: - activate()

  @Test func activateSetsIsActiveTrue() {
    let state = ElementInspectState()
    state.activate()
    #expect(state.isActive == true)
  }

  @Test func activateClearsPreviousSelection() {
    let state = ElementInspectState()
    state.selectElement(TestFixtures.makeButton())
    state.activate()
    #expect(state.selectedElement == nil)
    #expect(state.selectedElementViewportRect == nil)
    #expect(state.isInputShowing == false)
  }

  // MARK: - selectElement(_:)

  @Test func selectElementStoresElement() {
    let state = ElementInspectState()
    let element = TestFixtures.makeButton()
    state.selectElement(element)
    #expect(state.selectedElement == element)
    #expect(state.selectedElementViewportRect == element.boundingRect)
  }

  @Test func selectElementMakesInputShowing() {
    let state = ElementInspectState()
    state.selectElement(TestFixtures.makeButton())
    #expect(state.isInputShowing == true)
  }

  // MARK: - dismissInput()

  @Test func dismissInputClearsElement() {
    let state = ElementInspectState()
    state.activate()
    state.selectElement(TestFixtures.makeButton())
    state.dismissInput()
    #expect(state.selectedElement == nil)
    #expect(state.selectedElementViewportRect == nil)
    #expect(state.isInputShowing == false)
  }

  @Test func dismissInputKeepsIsActive() {
    let state = ElementInspectState()
    state.activate()
    state.selectElement(TestFixtures.makeButton())
    state.dismissInput()
    #expect(state.isActive == true)
  }

  // MARK: - deactivate()

  @Test func deactivateSetsIsActiveFalse() {
    let state = ElementInspectState()
    state.activate()
    state.deactivate()
    #expect(state.isActive == false)
  }

  @Test func deactivateClearsSelection() {
    let state = ElementInspectState()
    state.activate()
    state.selectElement(TestFixtures.makeButton())
    state.deactivate()
    #expect(state.selectedElement == nil)
    #expect(state.selectedElementViewportRect == nil)
  }

  @Test func updateSelectedElementViewportRectOnlyTouchesGeometry() {
    let state = ElementInspectState()
    let element = TestFixtures.makeButton()
    let updatedRect = CGRect(x: 44, y: 88, width: 160, height: 52)

    state.selectElement(element)
    state.updateSelectedElementViewportRect(updatedRect)

    #expect(state.selectedElement == element)
    #expect(state.selectedElement?.id == element.id)
    #expect(state.selectedElementViewportRect == updatedRect)
  }

  // MARK: - Lifecycle & Edge Cases

  @Test func fullLifecycleSequence() {
    let state = ElementInspectState()

    // Activate
    state.activate()
    #expect(state.isActive == true)
    #expect(state.selectedElement == nil)

    // Select element
    let element = TestFixtures.makeButton()
    state.selectElement(element)
    #expect(state.selectedElement == element)
    #expect(state.isInputShowing == true)

    // Dismiss input
    state.dismissInput()
    #expect(state.selectedElement == nil)
    #expect(state.isActive == true)

    // Deactivate
    state.deactivate()
    #expect(state.isActive == false)
    #expect(state.selectedElement == nil)
  }

  @Test func deactivateFromColdState() {
    let state = ElementInspectState()
    state.deactivate()
    #expect(state.isActive == false)
    #expect(state.selectedElement == nil)
  }

  @Test func doubleActivateIsIdempotent() {
    let state = ElementInspectState()
    state.activate()
    state.activate()
    #expect(state.isActive == true)
    #expect(state.selectedElement == nil)
  }

  // MARK: - InspectMode

  @Test func activateDefaultsToInputMode() {
    let state = ElementInspectState()
    state.activate()
    #expect(state.mode == .input)
    #expect(state.isContextMode == false)
  }

  @Test func activateWithContextMode() {
    let state = ElementInspectState()
    state.activate(mode: .context)
    #expect(state.isActive == true)
    #expect(state.mode == .context)
    #expect(state.isContextMode == true)
  }

  @Test func activateWithContextModeClearsSelection() {
    let state = ElementInspectState()
    state.selectElement(TestFixtures.makeButton())
    state.activate(mode: .context)
    #expect(state.selectedElement == nil)
  }

  @Test func contextModeLifecycle() {
    let state = ElementInspectState()

    // Activate in context mode
    state.activate(mode: .context)
    #expect(state.isActive == true)
    #expect(state.isContextMode == true)

    // Select element
    let element = TestFixtures.makeButton()
    state.selectElement(element)
    #expect(state.selectedElement == element)
    #expect(state.isInputShowing == true)

    // Dismiss input (simulates auto-dismiss after context send)
    state.dismissInput()
    #expect(state.selectedElement == nil)
    #expect(state.isActive == true) // stays active in context mode
    #expect(state.isContextMode == true)

    // Deactivate
    state.deactivate()
    #expect(state.isActive == false)
  }
}
