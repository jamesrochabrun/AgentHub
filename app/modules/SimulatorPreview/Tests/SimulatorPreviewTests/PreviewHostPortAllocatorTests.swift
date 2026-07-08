import Testing

@testable import SimulatorPreview

@Suite("PreviewHostPortAllocator")
struct PreviewHostPortAllocatorTests {

  @Test("same UDID always gets the same port")
  func deterministic() {
    let udid = "3C9E4F2A-1111-4A6B-9C3D-ABCDEF012345"
    #expect(
      PreviewHostPortAllocator.port(forDeviceUDID: udid)
        == PreviewHostPortAllocator.port(forDeviceUDID: udid)
    )
  }

  @Test("ports stay inside the loopback range")
  func inRange() {
    for udid in ["A", "B", "3C9E4F2A", "long-udid-\(String(repeating: "x", count: 64))"] {
      let port = PreviewHostPortAllocator.port(forDeviceUDID: udid)
      #expect(PreviewHostPortAllocator.portRange.contains(port))
    }
  }

  @Test("distinct UDIDs land on distinct ports for a realistic device set")
  func distinctForTypicalSet() {
    let udids = (0..<12).map { "DEVICE-\($0)-4A6B-9C3D-ABCDEF01234\($0)" }
    let ports = Set(udids.map { PreviewHostPortAllocator.port(forDeviceUDID: $0) })
    // Collisions are theoretically possible but should be rare in a
    // 12-device / 1000-slot space; total collapse would indicate a bug.
    #expect(ports.count >= udids.count - 1)
  }

  @Test("avoided ports are probed past, wrapping the range")
  func probesPastAvoided() {
    let udid = "COLLIDE-ME"
    let base = PreviewHostPortAllocator.port(forDeviceUDID: udid)
    let next = PreviewHostPortAllocator.port(forDeviceUDID: udid, avoiding: [base])
    #expect(next != base)
    #expect(PreviewHostPortAllocator.portRange.contains(next))

    let range = PreviewHostPortAllocator.portRange
    let wrapped = PreviewHostPortAllocator.port(
      forDeviceUDID: udid,
      avoiding: Set(base...range.upperBound)
    )
    #expect(wrapped < base)
    #expect(range.contains(wrapped))
  }
}
