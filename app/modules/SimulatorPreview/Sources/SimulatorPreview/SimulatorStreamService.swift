import Foundation

/// Default `SimulatorStreamServiceProtocol` implementation.
///
/// Owns one capture session per booted device UDID and reuses it across UI
/// mounts so re-opening the panel doesn't re-tap the framebuffer.
@MainActor
public final class SimulatorStreamService: SimulatorStreamServiceProtocol {
  public static let shared = SimulatorStreamService()

  public let availability: SimulatorStreamAvailability
  private let developerDir: String
  private var sessions: [String: SimulatorStreamSession] = [:]

  public init(
    developerDir: String = XcodeDeveloperDirectory.resolved,
    availability: SimulatorStreamAvailability? = nil
  ) {
    self.developerDir = developerDir
    self.availability = availability ?? SimulatorStreamAvailability.probe(developerDir: developerDir)
  }

  public func session(forDeviceUDID udid: String) -> any SimulatorStreamSessionProtocol {
    if let existing = sessions[udid] {
      return existing
    }
    let session = SimulatorStreamSession(
      udid: udid, availability: availability, developerDir: developerDir)
    sessions[udid] = session
    return session
  }

  public func discardSession(forDeviceUDID udid: String) {
    sessions[udid]?.stop()
    sessions[udid] = nil
  }

  public func stopAll() {
    for session in sessions.values {
      session.stop()
    }
    sessions.removeAll()
  }
}
