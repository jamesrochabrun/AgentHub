import CoreGraphics
import Testing
@testable import Canvas

@Suite("WebInspectInputLayoutResolver")
struct WebInspectInputLayoutResolverTests {

  @Test func anchorsBelowVisibleElement() {
    let layout = WebInspectInputLayoutResolver.resolve(
      containerHeight: 800,
      elementRect: CGRect(x: 100, y: 220, width: 180, height: 44),
      inputHeight: 120,
      topInset: 12,
      bottomInset: 12,
      gap: 12
    )

    #expect(layout == WebInspectInputResolvedLayout(topOffset: 276, clamp: .none))
  }

  @Test func clampsToTopWhenElementIsNearTop() {
    let layout = WebInspectInputLayoutResolver.resolve(
      containerHeight: 800,
      elementRect: CGRect(x: 100, y: -40, width: 180, height: 24),
      inputHeight: 120,
      topInset: 12,
      bottomInset: 12,
      gap: 12
    )

    #expect(layout == WebInspectInputResolvedLayout(topOffset: 12, clamp: .top))
  }

  @Test func clampsToBottomWhenElementIsNearBottom() {
    let layout = WebInspectInputLayoutResolver.resolve(
      containerHeight: 800,
      elementRect: CGRect(x: 100, y: 720, width: 180, height: 44),
      inputHeight: 120,
      topInset: 12,
      bottomInset: 12,
      gap: 12
    )

    #expect(layout == WebInspectInputResolvedLayout(topOffset: 668, clamp: .bottom))
  }

  @Test func staysPinnedTopWhenElementScrollsAboveViewport() {
    let layout = WebInspectInputLayoutResolver.resolve(
      containerHeight: 800,
      elementRect: CGRect(x: 100, y: -220, width: 180, height: 40),
      inputHeight: 120,
      topInset: 12,
      bottomInset: 12,
      gap: 12
    )

    #expect(layout == WebInspectInputResolvedLayout(topOffset: 12, clamp: .top))
  }

  @Test func staysPinnedBottomWhenElementScrollsBelowViewport() {
    let layout = WebInspectInputLayoutResolver.resolve(
      containerHeight: 800,
      elementRect: CGRect(x: 100, y: 920, width: 180, height: 40),
      inputHeight: 120,
      topInset: 12,
      bottomInset: 12,
      gap: 12
    )

    #expect(layout == WebInspectInputResolvedLayout(topOffset: 668, clamp: .bottom))
  }

  @Test func returnsToAnchoredPositionWhenElementReentersViewport() {
    let layout = WebInspectInputLayoutResolver.resolve(
      containerHeight: 800,
      elementRect: CGRect(x: 100, y: 380, width: 180, height: 40),
      inputHeight: 120,
      topInset: 12,
      bottomInset: 12,
      gap: 12
    )

    #expect(layout == WebInspectInputResolvedLayout(topOffset: 432, clamp: .none))
  }
}
