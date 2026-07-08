import CryptoKit
import Foundation

/// Assigns each simulator device its own loopback port for the preview host,
/// so multiple projects/worktrees can serve previews simultaneously instead
/// of fighting over one fixed port.
///
/// The port is a stable hash of the device UDID: the same device always gets
/// the same port (the host-side client and the in-app server derive nothing —
/// AgentHub computes the port once per launch and passes it through the
/// launch environment). `avoiding` lets a caller probe past ports already
/// claimed by other live sessions on hash collision.
public enum PreviewHostPortAllocator {

  /// Loopback-only range, clear of the legacy fixed port's neighbors and
  /// common dev-server ports. 1000 slots.
  public static let portRange: ClosedRange<Int> = 38700...39699

  public static func port(forDeviceUDID udid: String, avoiding: Set<Int> = []) -> Int {
    let count = portRange.count
    let digest = SHA256.hash(data: Data(udid.utf8))
    let seed = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    var offset = Int(seed % UInt64(count))
    for _ in 0..<count {
      let candidate = portRange.lowerBound + offset
      if !avoiding.contains(candidate) {
        return candidate
      }
      offset = (offset + 1) % count
    }
    // Every slot avoided (not realistic) — return the deterministic base.
    return portRange.lowerBound + Int(seed % UInt64(count))
  }
}
