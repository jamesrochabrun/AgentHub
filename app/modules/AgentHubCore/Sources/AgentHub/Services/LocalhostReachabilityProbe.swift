//
//  LocalhostReachabilityProbe.swift
//  AgentHub
//
//  Fast TCP reachability probe used before handing an agent-advertised
//  localhost URL to WKWebView. A pure handshake check avoids WebKit blanking
//  the preview while it waits for a connection that will never succeed.
//

import Foundation
import Network

/// Protocol-fronted reachability check so tests can inject a mock result.
public protocol LocalhostReachabilityProbing: Sendable {
  /// Returns `true` if a TCP connection to the URL's host/port can be
  /// established within the probe's timeout, `false` otherwise.
  func isReachable(_ url: URL) async -> Bool
}

/// Default production implementation backed by `Network.NWConnection`.
///
/// The probe does no HTTP work — it completes as soon as the TCP handshake
/// succeeds (or fails) so it works for any framework's dev server and adds
/// only a few milliseconds on the happy path.
public struct LocalhostReachabilityProbe: LocalhostReachabilityProbing {
  /// Maximum time to wait before declaring the URL unreachable.
  public let timeout: Duration

  public init(timeout: Duration = .milliseconds(1500)) {
    self.timeout = timeout
  }

  public func isReachable(_ url: URL) async -> Bool {
    guard let host = url.host, !host.isEmpty else { return false }
    let port = Self.port(from: url)
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }

    let endpoint = NWEndpoint.hostPort(host: .init(host), port: nwPort)
    let parameters = NWParameters.tcp
    parameters.prohibitedInterfaceTypes = [.cellular]

    let connection = NWConnection(to: endpoint, using: parameters)
    let sleepDuration = timeout

    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let state = ProbeState()

      connection.stateUpdateHandler = { newState in
        switch newState {
        case .ready:
          if state.claim() {
            connection.cancel()
            continuation.resume(returning: true)
          }
        case .failed, .cancelled:
          if state.claim() {
            connection.cancel()
            continuation.resume(returning: false)
          }
        case .waiting:
          // NWConnection reports `.waiting` when the OS can't complete the
          // handshake immediately (e.g. connection refused, no route). For
          // loopback URLs we treat this as unreachable right away rather
          // than waiting for the full timeout.
          if state.claim() {
            connection.cancel()
            continuation.resume(returning: false)
          }
        default:
          break
        }
      }

      connection.start(queue: .global(qos: .userInitiated))

      Task {
        try? await Task.sleep(for: sleepDuration)
        if state.claim() {
          connection.cancel()
          continuation.resume(returning: false)
        }
      }
    }
  }

  private static func port(from url: URL) -> Int {
    if let explicit = url.port { return explicit }
    switch url.scheme?.lowercased() {
    case "https": return 443
    default: return 80
    }
  }
}

/// Thread-safe one-shot latch for the probe's continuation. The NWConnection
/// callback and the timeout task race each other; only the first one wins.
private final class ProbeState: @unchecked Sendable {
  private let lock = NSLock()
  private var resolved = false

  /// Returns `true` if the caller is the first to claim the latch (and
  /// therefore responsible for resuming the continuation).
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !resolved else { return false }
    resolved = true
    return true
  }
}
