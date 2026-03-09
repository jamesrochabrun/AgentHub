//
//  TerminalStreamProxy.swift
//  AgentHub
//
//  Central registry bridging PTY terminal sessions to WebSocket clients.
//

import Combine
import Foundation

/// Central registry bridging PTY terminal sessions to WebSocket clients.
/// @MainActor because it interacts with ManagedLocalProcessTerminalView (a view class).
@MainActor
public final class TerminalStreamProxy {
  public static let shared = TerminalStreamProxy()
  private init() {}

  // sessionId → weak reference to the terminal view
  private var terminals: [String: WeakTerminalRef] = [:]
  // sessionId → active Combine subscriptions (one per registered terminal)
  private var cancellables: [String: AnyCancellable] = [:]
  // sessionId → list of WebSocket listeners
  private var listeners: [String: [any TerminalListener]] = [:]
  // sessionId → recent PTY bytes for replaying to newly connected clients
  private var scrollbackBuffers: [String: Data] = [:]
  // sessionId → current PTY dimensions, sent to newly connecting web clients
  private var currentSizes: [String: (cols: Int, rows: Int)] = [:]
  private let maxScrollbackSize = 512 * 1024  // 512 KB

  // MARK: - Registration (called by EmbeddedTerminalView on appear/disappear)

  public func register(sessionId: String, terminal: ManagedLocalProcessTerminalView) {
    terminals[sessionId] = WeakTerminalRef(terminal)
    scrollbackBuffers.removeValue(forKey: sessionId)  // Clear stale scrollback from previous run
    // Subscribe to PTY output and broadcast to all listeners for this session
    cancellables[sessionId] = terminal.dataPublisher
      .receive(on: DispatchQueue.global(qos: .userInteractive))
      .sink { [weak self] data in
        Task { @MainActor [weak self] in
          self?.broadcast(sessionId: sessionId, data: data)
        }
      }
  }

  public func unregister(sessionId: String) {
    cancellables.removeValue(forKey: sessionId)
    terminals.removeValue(forKey: sessionId)
    scrollbackBuffers.removeValue(forKey: sessionId)
    currentSizes.removeValue(forKey: sessionId)
    // Notify listeners the session ended
    listeners[sessionId]?.forEach { $0.onClose() }
    listeners.removeValue(forKey: sessionId)
  }

  // MARK: - Listener management (called by AgentHubWebServer)

  public func addListener(_ listener: any TerminalListener, for sessionId: String) {
    // Send current terminal size so xterm.js initializes at the correct dimensions
    if let size = currentSizes[sessionId] {
      listener.onResize(cols: size.cols, rows: size.rows)
    }
    // Replay scrollback so the new client sees existing terminal state
    if let scrollback = scrollbackBuffers[sessionId], !scrollback.isEmpty {
      listener.onData(scrollback)
    }
    listeners[sessionId, default: []].append(listener)
  }

  public func removeListener(_ listener: any TerminalListener, for sessionId: String) {
    listeners[sessionId]?.removeAll { $0 === listener }
  }

  // MARK: - Data flow

  private func broadcast(sessionId: String, data: Data) {
    // Append to scrollback buffer, trimming if over limit
    var buffer = scrollbackBuffers[sessionId] ?? Data()
    buffer.append(data)
    if buffer.count > maxScrollbackSize {
      buffer = Data(buffer.suffix(maxScrollbackSize))
    }
    scrollbackBuffers[sessionId] = buffer

    listeners[sessionId]?.forEach { $0.onData(data) }
  }

  public func broadcastResize(sessionId: String, cols: Int, rows: Int) {
    currentSizes[sessionId] = (cols: cols, rows: rows)
    listeners[sessionId]?.forEach { $0.onResize(cols: cols, rows: rows) }
  }

  public func writeInput(sessionId: String, data: Data) {
    terminals[sessionId]?.value?.writeToProcess(data)
  }

  public func resize(sessionId: String, cols: Int, rows: Int) {
    terminals[sessionId]?.value?.resizePTY(cols: cols, rows: rows)
  }

  // MARK: - Inspection

  public func hasTerminal(for sessionId: String) -> Bool {
    terminals[sessionId]?.value != nil
  }
}

// MARK: - Supporting types

private final class WeakTerminalRef {
  weak var value: ManagedLocalProcessTerminalView?
  init(_ value: ManagedLocalProcessTerminalView) { self.value = value }
}

/// Callbacks from TerminalStreamProxy to a WebSocket connection handler.
/// `AnyObject` constraint required for `removeAll { $0 === listener }` identity comparison.
public protocol TerminalListener: AnyObject {
  func onData(_ data: Data)
  func onResize(cols: Int, rows: Int)
  func onClose()
}
