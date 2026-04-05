import Foundation
import Network
import Testing

@testable import AgentHubCore

@Suite("LocalhostReachabilityProbe")
struct LocalhostReachabilityProbeTests {

  @Test("Returns true when a TCP listener accepts connections on the URL's port")
  func reachableWhenListenerAcceptsConnections() async throws {
    let listener = try TestTCPListener()
    defer { listener.stop() }
    try listener.start()

    let probe = LocalhostReachabilityProbe(timeout: .milliseconds(1500))
    let url = URL(string: "http://127.0.0.1:\(listener.port)/")!

    let reachable = await probe.isReachable(url)
    #expect(reachable == true)
  }

  @Test("Returns false when the target port is not listening")
  func unreachableWhenPortIsClosed() async throws {
    // Start a listener to grab a free port, then stop it so the port
    // becomes unreachable. This is more reliable than picking a random port.
    let listener = try TestTCPListener()
    try listener.start()
    let port = listener.port
    listener.stop()

    // Give the kernel a moment to fully release the socket.
    try? await Task.sleep(for: .milliseconds(50))

    let probe = LocalhostReachabilityProbe(timeout: .milliseconds(800))
    let url = URL(string: "http://127.0.0.1:\(port)/")!

    let reachable = await probe.isReachable(url)
    #expect(reachable == false)
  }

  @Test("Returns false for a URL without a host")
  func unreachableWithoutHost() async {
    let probe = LocalhostReachabilityProbe(timeout: .milliseconds(200))
    let url = URL(string: "http:///path")!

    let reachable = await probe.isReachable(url)
    #expect(reachable == false)
  }
}

// MARK: - Test TCP Listener

/// Tiny one-shot TCP listener used to verify the probe's happy path without
/// depending on an external server or a specific hard-coded port.
private final class TestTCPListener: @unchecked Sendable {
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "TestTCPListener")
  private(set) var port: UInt16 = 0

  func start() throws {
    let parameters = NWParameters.tcp
    let listener = try NWListener(using: parameters, on: .any)
    self.listener = listener

    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        if let port = listener.port?.rawValue {
          self?.port = port
        }
        ready.signal()
      }
    }
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      connection.cancel()
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 2)
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }
}

