import CryptoKit
import Foundation
import Network

// MARK: - AgentHubWebServer

/// Embedded HTTP + WebSocket server that streams PTY terminal sessions to browser clients.
/// Listens on a configurable TCP port and serves a single-page web app with xterm.js.
public actor AgentHubWebServer {

  private var listener: NWListener?
  private var activeSessions: [ObjectIdentifier: WebSocketClientSession] = [:]
  private let port: UInt16
  /// Provides the current list of monitored sessions for the /api/sessions endpoint.
  private let sessionProvider: @Sendable () async -> [WebSessionInfo]
  /// Called when the web client selects a session (POST /api/sessions/{id}/focus).
  private let sessionFocusHandler: (@Sendable (String) async -> Void)?

  public init(
    port: UInt16,
    sessionProvider: @Sendable @escaping () async -> [WebSessionInfo],
    sessionFocusHandler: (@Sendable (String) async -> Void)? = nil
  ) {
    self.port = port
    self.sessionProvider = sessionProvider
    self.sessionFocusHandler = sessionFocusHandler
  }

  // MARK: - Lifecycle

  public func start() throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw URLError(.badURL)
    }
    let listener = try NWListener(using: params, on: nwPort)
    self.listener = listener

    listener.newConnectionHandler = { [weak self] connection in
      Task { [weak self] in
        await self?.handleNewConnection(connection)
      }
    }
    listener.start(queue: .global(qos: .utility))
  }

  public func stop() {
    activeSessions.values.forEach { $0.cancel() }
    activeSessions.removeAll()
    listener?.cancel()
    listener = nil
  }

  // MARK: - Connection handling

  private func handleNewConnection(_ connection: NWConnection) {
    let session = WebSocketClientSession(connection: connection, server: self)
    activeSessions[ObjectIdentifier(session)] = session
    session.start()
  }

  func sessionDidClose(_ session: WebSocketClientSession) {
    activeSessions.removeValue(forKey: ObjectIdentifier(session))
  }

  // MARK: - Request routing

  /// Routes an HTTP request to the appropriate handler. Called by WebSocketClientSession.
  func route(path: String, method: String) async -> HTTPResponse {
    switch (method, path) {
    case ("GET", "/"), ("GET", "/index.html"):
      return serveFile(name: "index", ext: "html", contentType: "text/html; charset=utf-8")

    case ("GET", "/xterm.js"):
      return serveFile(name: "xterm", ext: "js", contentType: "application/javascript")

    case ("GET", "/xterm.css"):
      return serveFile(name: "xterm", ext: "css", contentType: "text/css")

    case ("GET", "/api/sessions"):
      let sessions = await sessionProvider()
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      if let data = try? encoder.encode(sessions) {
        return HTTPResponse(status: 200, contentType: "application/json", body: data)
      }
      return HTTPResponse(status: 500, contentType: "text/plain", body: Data("Encoding error".utf8))

    case ("POST", _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/focus"):
      let sessionId = String(path.dropFirst("/api/sessions/".count).dropLast("/focus".count))
      if !sessionId.isEmpty, let handler = sessionFocusHandler {
        await handler(sessionId)
      }
      return HTTPResponse(status: 200, contentType: "application/json", body: Data("{}".utf8))

    default:
      return HTTPResponse(status: 404, contentType: "text/plain", body: Data("Not found".utf8))
    }
  }

  /// Called when a WebSocket client connects to a terminal session.
  func terminalWebSocketOpened(sessionId: String, client: WebSocketClientSession) {
    Task { @MainActor in
      TerminalStreamProxy.shared.addListener(client, for: sessionId)
    }
  }

  /// Called when a WebSocket client disconnects from a terminal session.
  func terminalWebSocketClosed(sessionId: String, client: WebSocketClientSession) {
    Task { @MainActor in
      TerminalStreamProxy.shared.removeListener(client, for: sessionId)
    }
  }

  // MARK: - Static file serving

  private func serveFile(name: String, ext: String, contentType: String) -> HTTPResponse {
    if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "WebClient"),
       let data = try? Data(contentsOf: url) {
      return HTTPResponse(status: 200, contentType: contentType, body: data)
    }
    return HTTPResponse(status: 404, contentType: "text/plain",
                        body: Data("File not found: \(name).\(ext)".utf8))
  }
}

// MARK: - HTTPResponse

struct HTTPResponse: Sendable {
  let status: Int
  let contentType: String
  let body: Data

  func toData() -> Data {
    let statusText: String
    switch status {
    case 200: statusText = "OK"
    case 404: statusText = "Not Found"
    default:  statusText = "Error"
    }
    let header = [
      "HTTP/1.1 \(status) \(statusText)",
      "Content-Type: \(contentType)",
      "Content-Length: \(body.count)",
      "Access-Control-Allow-Origin: *",
      "Connection: close",
      "", ""
    ].joined(separator: "\r\n")
    return Data(header.utf8) + body
  }
}

// MARK: - WebSocketClientSession

/// Manages one browser connection: HTTP parsing → WebSocket upgrade → bidirectional PTY stream.
/// Conforms to TerminalListener to receive PTY output from TerminalStreamProxy.
final class WebSocketClientSession: TerminalListener, @unchecked Sendable {
  private let connection: NWConnection
  private weak var server: AgentHubWebServer?
  private var receiveBuffer = Data()
  private var isWebSocket = false
  private var terminalSessionId: String?

  init(connection: NWConnection, server: AgentHubWebServer) {
    self.connection = connection
    self.server = server
  }

  func start() {
    connection.start(queue: .global(qos: .userInteractive))
    receiveNext()
  }

  func cancel() {
    connection.cancel()
  }

  // MARK: - Receive loop

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.receiveBuffer.append(data)
        if self.isWebSocket {
          self.processWebSocketFrames()
        } else {
          self.processHTTPRequest()
        }
      }
      if isComplete || error != nil {
        self.closeCleanly()
        return
      }
      self.receiveNext()
    }
  }

  // MARK: - HTTP parsing

  private func processHTTPRequest() {
    guard let requestStr = String(data: receiveBuffer, encoding: .utf8),
          requestStr.contains("\r\n\r\n") else { return }
    // Keep only bytes after the header end (body or pipelined data)
    if let headerEnd = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) {
      receiveBuffer = Data(receiveBuffer[(headerEnd.upperBound)...])
    } else {
      receiveBuffer.removeAll()
    }

    let lines = requestStr.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return }
    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else { return }
    let method = parts[0]
    let fullPath = parts[1]
    let path = fullPath.components(separatedBy: "?").first ?? fullPath

    // Check for WebSocket upgrade
    let headersLower = lines.dropFirst().joined(separator: "\r\n").lowercased()
    if headersLower.contains("upgrade: websocket") {
      if let keyLine = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) {
        let key = String(keyLine.split(separator: ":", maxSplits: 1).dropFirst().first ?? "")
          .trimmingCharacters(in: .whitespaces)
        upgradeToWebSocket(key: key, path: path)
      }
    } else {
      Task { [weak self] in
        guard let self, let server = self.server else { return }
        let response = await server.route(path: path, method: method)
        self.sendRaw(response.toData()) {
          self.connection.cancel()
        }
      }
    }
  }

  // MARK: - WebSocket upgrade

  private func upgradeToWebSocket(key: String, path: String) {
    let accept = webSocketAcceptValue(for: key)
    let response = [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Accept: \(accept)",
      "", ""
    ].joined(separator: "\r\n")
    sendRaw(Data(response.utf8))
    isWebSocket = true

    // Extract session ID from path: /ws/terminal/{sessionId}
    let prefix = "/ws/terminal/"
    if path.hasPrefix(prefix) {
      let sessionId = String(path.dropFirst(prefix.count))
      terminalSessionId = sessionId
      Task { [weak self] in
        guard let self, let server = self.server else { return }
        await server.terminalWebSocketOpened(sessionId: sessionId, client: self)
      }
    }
  }

  private func webSocketAcceptValue(for key: String) -> String {
    let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let hash = Insecure.SHA1.hash(data: Data((key + magic).utf8))
    return Data(hash).base64EncodedString()
  }

  // MARK: - WebSocket frame processing

  private func processWebSocketFrames() {
    while let frame = parseNextFrame() {
      handleFrame(opcode: frame.opcode, payload: frame.payload)
    }
  }

  private func handleFrame(opcode: UInt8, payload: Data) {
    switch opcode {
    case 0x01, 0x02: // text or binary frame — terminal input or control
      handleClientPayload(payload)
    case 0x08: // close
      closeCleanly()
    case 0x09: // ping → pong
      sendFrame(payload: payload, opcode: 0x0A)
    default:
      break
    }
  }

  private func handleClientPayload(_ data: Data) {
    guard let sessionId = terminalSessionId else { return }
    // Try JSON control message first (resize)
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let type = json["type"] as? String, type == "resize",
       let cols = json["cols"] as? Int, let rows = json["rows"] as? Int {
      Task { @MainActor in
        TerminalStreamProxy.shared.resize(sessionId: sessionId, cols: cols, rows: rows)
      }
    } else {
      // Raw keyboard input → write to PTY
      Task { @MainActor in
        TerminalStreamProxy.shared.writeInput(sessionId: sessionId, data: data)
      }
    }
  }

  // MARK: - TerminalListener (called from TerminalStreamProxy on main actor)

  func onData(_ data: Data) {
    sendFrame(payload: data, opcode: 0x02) // binary frame
  }

  func onResize(cols: Int, rows: Int) {
    let json = "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
    sendFrame(payload: Data(json.utf8), opcode: 0x01) // text frame
  }

  func onClose() {
    sendFrame(payload: Data(), opcode: 0x08) // close frame
    connection.cancel()
  }

  // MARK: - Cleanup

  private func closeCleanly() {
    let sessionId = terminalSessionId
    terminalSessionId = nil
    connection.cancel()
    Task { [weak self] in
      guard let self, let server = self.server else { return }
      if let sessionId {
        await server.terminalWebSocketClosed(sessionId: sessionId, client: self)
      }
      await server.sessionDidClose(self)
    }
  }

  // MARK: - RFC 6455 WebSocket frame encode/decode

  private func sendFrame(payload: Data, opcode: UInt8) {
    var frame = Data()
    frame.append(0x80 | opcode) // FIN=1
    let len = payload.count
    if len < 126 {
      frame.append(UInt8(len))
    } else if len < 65536 {
      frame.append(126)
      frame.append(UInt8((len >> 8) & 0xFF))
      frame.append(UInt8(len & 0xFF))
    } else {
      frame.append(127)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((len >> shift) & 0xFF))
      }
    }
    frame.append(contentsOf: payload)
    sendRaw(frame)
  }

  private struct ParsedFrame {
    let opcode: UInt8
    let payload: Data
    let totalBytes: Int
  }

  private func parseNextFrame() -> ParsedFrame? {
    let buf = receiveBuffer
    guard buf.count >= 2 else { return nil }

    let opcode = buf[0] & 0x0F
    let masked = (buf[1] & 0x80) != 0
    var payloadLen = Int(buf[1] & 0x7F)
    var offset = 2

    if payloadLen == 126 {
      guard buf.count >= 4 else { return nil }
      payloadLen = Int(buf[2]) << 8 | Int(buf[3])
      offset = 4
    } else if payloadLen == 127 {
      guard buf.count >= 10 else { return nil }
      payloadLen = (0..<8).reduce(0) { acc, i in acc << 8 | Int(buf[2 + i]) }
      offset = 10
    }

    let maskSize = masked ? 4 : 0
    let totalNeeded = offset + maskSize + payloadLen
    guard buf.count >= totalNeeded else { return nil }

    var payload = Data(buf[(offset + maskSize)..<(offset + maskSize + payloadLen)])
    if masked {
      let mask = [buf[offset], buf[offset+1], buf[offset+2], buf[offset+3]]
      for i in 0..<payload.count {
        payload[i] ^= mask[i % 4]
      }
    }

    receiveBuffer = Data(buf.dropFirst(totalNeeded))
    return ParsedFrame(opcode: opcode, payload: payload, totalBytes: totalNeeded)
  }

  // MARK: - Raw send

  private func sendRaw(_ data: Data, completion: (() -> Void)? = nil) {
    if let completion {
      connection.send(content: data, completion: .contentProcessed { _ in completion() })
    } else {
      connection.send(content: data, completion: .idempotent)
    }
  }
}
