import CoreGraphics
import Testing

@testable import SimulatorPreview

@Suite("SimulatorPointMapper")
struct SimulatorPointMapperTests {
  @Test("aspect-fit letterboxes a tall device in a wide view")
  func aspectFitWideView() {
    // 100x200 content (portrait) in a 400x200 view → pillarboxed.
    let rect = SimulatorPointMapper.aspectFitRect(
      contentSize: CGSize(width: 100, height: 200),
      in: CGSize(width: 400, height: 200))
    #expect(rect.height == 200)
    #expect(rect.width == 100)
    #expect(rect.minX == 150)  // centered
    #expect(rect.minY == 0)
  }

  @Test("center of content maps to (0.5, 0.5)")
  func centerMapping() {
    let p = SimulatorPointMapper.normalizedPoint(
      viewPoint: CGPoint(x: 200, y: 100),
      contentSize: CGSize(width: 100, height: 200),
      viewSize: CGSize(width: 400, height: 200))
    #expect(p != nil)
    #expect(abs((p?.x ?? 0) - 0.5) < 0.0001)
    #expect(abs((p?.y ?? 0) - 0.5) < 0.0001)
  }

  @Test("top-left corner of content maps to origin")
  func topLeftMapping() {
    let p = SimulatorPointMapper.normalizedPoint(
      viewPoint: CGPoint(x: 150, y: 0),
      contentSize: CGSize(width: 100, height: 200),
      viewSize: CGSize(width: 400, height: 200))
    #expect(p != nil)
    #expect(abs((p?.x ?? 1) - 0) < 0.0001)
    #expect(abs((p?.y ?? 1) - 0) < 0.0001)
  }

  @Test("clicks in the letterbox bars return nil")
  func letterboxReturnsNil() {
    // x=10 is in the left pillarbox (content starts at x=150).
    let p = SimulatorPointMapper.normalizedPoint(
      viewPoint: CGPoint(x: 10, y: 100),
      contentSize: CGSize(width: 100, height: 200),
      viewSize: CGSize(width: 400, height: 200))
    #expect(p == nil)
  }

  @Test("clamped mapping pins points outside content to nearest edge")
  func clampedMappingPinsOutsideContent() throws {
    let p = try #require(SimulatorPointMapper.clampedNormalizedPoint(
      viewPoint: CGPoint(x: 10, y: 260),
      contentSize: CGSize(width: 100, height: 200),
      viewSize: CGSize(width: 400, height: 200)))
    #expect(p.x == 0)
    #expect(p.y == 1)
  }

  @Test("zero sizes degrade gracefully")
  func zeroSizes() {
    #expect(SimulatorPointMapper.aspectFitRect(contentSize: .zero, in: CGSize(width: 10, height: 10)) == .zero)
    #expect(SimulatorPointMapper.normalizedPoint(
      viewPoint: .zero, contentSize: .zero, viewSize: .zero) == nil)
    #expect(SimulatorPointMapper.clampedNormalizedPoint(
      viewPoint: .zero, contentSize: .zero, viewSize: .zero) == nil)
  }
}
