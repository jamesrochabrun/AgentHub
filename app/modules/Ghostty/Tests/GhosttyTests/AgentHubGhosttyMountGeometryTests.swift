import CoreGraphics
import Testing

@testable import Ghostty

@Suite("AgentHub Ghostty mount geometry")
struct AgentHubGhosttyMountGeometryTests {

  @Test("Zero-sized host geometry is not usable for terminal startup")
  func rejectsZeroSizedGeometry() {
    #expect(!AgentHubGhosttyMountGeometry.isUsable(.zero))
    #expect(!AgentHubGhosttyMountGeometry.isUsable(CGSize(width: 120, height: 0)))
    #expect(!AgentHubGhosttyMountGeometry.isUsable(CGSize(width: 0, height: 80)))
  }

  @Test("Positive host geometry is usable for terminal startup")
  func acceptsPositiveGeometry() {
    #expect(AgentHubGhosttyMountGeometry.isUsable(CGSize(width: 120, height: 80)))
  }

  @Test("Geometry is stable only after matching layout measurements")
  func detectsStableGeometry() {
    let first = CGSize(width: 320, height: 180)

    #expect(!AgentHubGhosttyMountGeometry.isStable(previous: nil, current: first))
    #expect(AgentHubGhosttyMountGeometry.isStable(previous: first, current: first))
  }

  @Test("Tiny layout jitter still counts as stable")
  func treatsTinyLayoutJitterAsStable() {
    let previous = CGSize(width: 320, height: 180)
    let current = CGSize(width: 320.25, height: 179.75)

    #expect(AgentHubGhosttyMountGeometry.isStable(previous: previous, current: current))
  }

  @Test("Meaningful layout changes are not stable")
  func rejectsMeaningfulLayoutChanges() {
    let previous = CGSize(width: 320, height: 180)
    let current = CGSize(width: 280, height: 180)

    #expect(!AgentHubGhosttyMountGeometry.isStable(previous: previous, current: current))
  }
}
