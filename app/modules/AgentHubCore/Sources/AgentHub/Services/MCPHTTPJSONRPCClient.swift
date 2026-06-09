//
//  MCPHTTPJSONRPCClient.swift
//  AgentHub
//

import AgentHubMCPUI
import Foundation

public final class MCPHTTPJSONRPCClient: MCPJSONRPCClientProtocol, @unchecked Sendable {
  private enum Mode: Sendable {
    case streamableHTTP(endpoint: URL, legacySSEFallback: Bool)
    case legacySSE(endpoint: URL)
  }

  private enum Fallback: Error {
    case legacySSE
  }

  private let mode: Mode
  private let requestTimeoutSeconds: TimeInterval
  private let session: URLSession
  private let stateLock = NSLock()
  private var nextID = 1
  private var sessionID: String?

  public init(
    config: MCPServerConfiguration,
    requestTimeoutSeconds: TimeInterval,
    session: URLSession = .shared
  ) throws {
    switch config.transport {
    case .streamableHTTP(let endpoint, let legacySSEFallback):
      self.mode = .streamableHTTP(endpoint: endpoint, legacySSEFallback: legacySSEFallback)
    case .sse(let endpoint):
      self.mode = .legacySSE(endpoint: endpoint)
    case .stdio:
      throw MCPAppDiscoveryError.unsupportedTransport("stdio")
    case .unsupportedAuthentication(let reason):
      throw MCPAppDiscoveryError.unsupportedAuthentication(reason)
    case .unsupported(let transport):
      throw MCPAppDiscoveryError.unsupportedTransport(transport)
    }
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.session = session
  }

  public func start() throws {}

  public func request(
    method: String,
    params: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    let id = nextRequestID()
    let envelope = MCPJSONRPCMessage.requestEnvelope(id: id, method: method, params: params)
    let started = Date()
    AppLogger.mcp.debug(
      "[MCPHTTP] request start id=\(id, privacy: .public) method=\(method, privacy: .public) endpoint=\(self.endpointDescription, privacy: .public)"
    )

    do {
      let result = try await withTimeout(method: method) {
        switch self.mode {
        case .streamableHTTP(let endpoint, let legacySSEFallback):
          do {
            return try await self.performStreamableHTTPMessage(
              envelope,
              expectedID: id,
              method: method,
              endpoint: endpoint,
              allowsLegacySSEFallback: legacySSEFallback
            )
          } catch Fallback.legacySSE where legacySSEFallback {
            AppLogger.mcp.info(
              "[MCPHTTP] legacy SSE fallback id=\(id, privacy: .public) method=\(method, privacy: .public) endpoint=\(self.redactedEndpointDescription(endpoint), privacy: .public)"
            )
            return try await self.performLegacySSEMessage(
              envelope,
              expectedID: id,
              method: method,
              sseEndpoint: endpoint
            )
          }
        case .legacySSE(let endpoint):
          return try await self.performLegacySSEMessage(
            envelope,
            expectedID: id,
            method: method,
            sseEndpoint: endpoint
          )
        }
      }
      let elapsed = Date().timeIntervalSince(started)
      AppLogger.mcp.debug(
        "[MCPHTTP] request done id=\(id, privacy: .public) method=\(method, privacy: .public) elapsed=\(elapsed, privacy: .public)"
      )
      return result
    } catch {
      let elapsed = Date().timeIntervalSince(started)
      AppLogger.mcp.error(
        "[MCPHTTP] request failed id=\(id, privacy: .public) method=\(method, privacy: .public) elapsed=\(elapsed, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  public func notify(method: String, params: AgentHubMCPUIJSONValue?) async throws {
    let envelope = MCPJSONRPCMessage.notificationEnvelope(method: method, params: params)
    let started = Date()
    AppLogger.mcp.debug(
      "[MCPHTTP] notify start method=\(method, privacy: .public) endpoint=\(self.endpointDescription, privacy: .public)"
    )

    do {
      try await withTimeout(method: method) {
        switch self.mode {
        case .streamableHTTP(let endpoint, let legacySSEFallback):
          do {
            try await self.performStreamableHTTPNotification(
              envelope,
              method: method,
              endpoint: endpoint,
              allowsLegacySSEFallback: legacySSEFallback
            )
          } catch Fallback.legacySSE where legacySSEFallback {
            AppLogger.mcp.info(
              "[MCPHTTP] legacy SSE fallback notification method=\(method, privacy: .public) endpoint=\(self.redactedEndpointDescription(endpoint), privacy: .public)"
            )
            try await self.performLegacySSENotification(envelope, method: method, sseEndpoint: endpoint)
          }
        case .legacySSE(let endpoint):
          try await self.performLegacySSENotification(envelope, method: method, sseEndpoint: endpoint)
        }
      }
      let elapsed = Date().timeIntervalSince(started)
      AppLogger.mcp.debug(
        "[MCPHTTP] notify done method=\(method, privacy: .public) elapsed=\(elapsed, privacy: .public)"
      )
    } catch {
      let elapsed = Date().timeIntervalSince(started)
      AppLogger.mcp.error(
        "[MCPHTTP] notify failed method=\(method, privacy: .public) elapsed=\(elapsed, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  public func close() {}

  private func performStreamableHTTPMessage(
    _ envelope: AgentHubMCPUIJSONValue,
    expectedID id: Int,
    method: String,
    endpoint: URL,
    allowsLegacySSEFallback: Bool
  ) async throws -> AgentHubMCPUIJSONValue {
    let (bytes, response) = try await bytes(for: postRequest(to: endpoint, body: envelope))
    let httpResponse = try await validateStreamableHTTPResponse(
      response,
      bytes: bytes,
      allowsLegacySSEFallback: allowsLegacySSEFallback
    )
    AppLogger.mcp.debug(
      "[MCPHTTP] streamable response method=\(method, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) contentType=\(self.contentType(from: httpResponse), privacy: .public) sessionID=\(httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") == nil ? "absent" : "present", privacy: .public)"
    )
    storeSessionID(from: httpResponse)

    if allowsLegacySSEFallback, shouldFallbackToLegacySSE(httpResponse) {
      throw Fallback.legacySSE
    }

    if contentType(from: httpResponse).contains("text/event-stream") {
      return try await resultFromSSEBytes(bytes, expectedID: id, method: method)
    }

    let data = try await data(from: bytes)
    return try result(from: data, response: httpResponse, expectedID: id, method: method)
  }

  private func performStreamableHTTPNotification(
    _ envelope: AgentHubMCPUIJSONValue,
    method: String,
    endpoint: URL,
    allowsLegacySSEFallback: Bool
  ) async throws {
    let (bytes, response) = try await bytes(for: postRequest(to: endpoint, body: envelope))
    let httpResponse = try await validateStreamableHTTPResponse(
      response,
      bytes: bytes,
      allowsLegacySSEFallback: allowsLegacySSEFallback
    )
    AppLogger.mcp.debug(
      "[MCPHTTP] streamable notification response method=\(method, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) contentType=\(self.contentType(from: httpResponse), privacy: .public) sessionID=\(httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") == nil ? "absent" : "present", privacy: .public)"
    )
    storeSessionID(from: httpResponse)

    if allowsLegacySSEFallback, shouldFallbackToLegacySSE(httpResponse) {
      throw Fallback.legacySSE
    }

    if !contentType(from: httpResponse).contains("text/event-stream") {
      _ = try await data(from: bytes)
    }
  }

  private func performLegacySSEMessage(
    _ envelope: AgentHubMCPUIJSONValue,
    expectedID id: Int,
    method: String,
    sseEndpoint: URL
  ) async throws -> AgentHubMCPUIJSONValue {
    var getRequest = URLRequest(url: sseEndpoint, timeoutInterval: requestTimeoutSeconds)
    getRequest.httpMethod = "GET"
    getRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    let (bytes, response) = try await bytes(for: getRequest)
    _ = try validateHTTPResponse(response, data: Data())

    var parser = MCPSSEEventParser()
    var didPost = false
    for try await line in bytes.lines {
      guard let event = parser.append(line: line) else { continue }

      if event.event == "endpoint" {
        let postEndpoint = try resolveLegacyPostEndpoint(event.data, relativeTo: sseEndpoint)
        try await postLegacySSEMessage(envelope, endpoint: postEndpoint, method: method)
        didPost = true
        continue
      }

      guard didPost, event.event == nil || event.event == "message" else { continue }
      guard let decoded = decodeSSEJSON(event.data) else { continue }
      if let result = try MCPJSONRPCMessage.result(from: decoded, expectedID: id, method: method) {
        return result
      }
    }

    if let event = parser.finish(),
       didPost,
       event.event == nil || event.event == "message",
       let decoded = decodeSSEJSON(event.data),
       let result = try MCPJSONRPCMessage.result(from: decoded, expectedID: id, method: method) {
      return result
    }

    throw MCPAppDiscoveryError.processClosed(method)
  }

  private func performLegacySSENotification(
    _ envelope: AgentHubMCPUIJSONValue,
    method: String,
    sseEndpoint: URL
  ) async throws {
    var getRequest = URLRequest(url: sseEndpoint, timeoutInterval: requestTimeoutSeconds)
    getRequest.httpMethod = "GET"
    getRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    let (bytes, response) = try await bytes(for: getRequest)
    _ = try validateHTTPResponse(response, data: Data())

    var parser = MCPSSEEventParser()
    for try await line in bytes.lines {
      guard let event = parser.append(line: line), event.event == "endpoint" else { continue }
      let postEndpoint = try resolveLegacyPostEndpoint(event.data, relativeTo: sseEndpoint)
      try await postLegacySSEMessage(envelope, endpoint: postEndpoint, method: method)
      return
    }

    if let event = parser.finish(), event.event == "endpoint" {
      let postEndpoint = try resolveLegacyPostEndpoint(event.data, relativeTo: sseEndpoint)
      try await postLegacySSEMessage(envelope, endpoint: postEndpoint, method: method)
      return
    }

    throw MCPAppDiscoveryError.processClosed(method)
  }

  private func postLegacySSEMessage(
    _ envelope: AgentHubMCPUIJSONValue,
    endpoint: URL,
    method: String
  ) async throws {
    let (data, response) = try await data(for: postRequest(to: endpoint, body: envelope))
    _ = try validateHTTPResponse(response, data: data)
  }

  private func postRequest(to endpoint: URL, body: AgentHubMCPUIJSONValue) throws -> URLRequest {
    var request = URLRequest(url: endpoint, timeoutInterval: requestTimeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(MCPJSONRPCMessage.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    if let sessionID = currentSessionID() {
      request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }
    request.httpBody = try JSONEncoder().encode(body)
    return request
  }

  private func result(
    from data: Data,
    response: HTTPURLResponse,
    expectedID id: Int,
    method: String
  ) throws -> AgentHubMCPUIJSONValue {
    guard !data.isEmpty else {
      throw MCPAppDiscoveryError.invalidResponse("HTTP response for \(method) did not include a body.")
    }

    if contentType(from: response).contains("text/event-stream") {
      return try resultFromSSEData(data, expectedID: id, method: method)
    }

    let decoded = try decodeJSON(data)
    guard let result = try MCPJSONRPCMessage.result(from: decoded, expectedID: id, method: method) else {
      throw MCPAppDiscoveryError.invalidResponse("HTTP response for \(method) did not match request id \(id).")
    }
    return result
  }

  private func resultFromSSEData(
    _ data: Data,
    expectedID id: Int,
    method: String
  ) throws -> AgentHubMCPUIJSONValue {
    guard let text = String(data: data, encoding: .utf8) else {
      throw MCPAppDiscoveryError.invalidResponse("SSE response for \(method) was not UTF-8.")
    }

    var parser = MCPSSEEventParser()
    for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
      guard let event = parser.append(line: line),
            event.event == nil || event.event == "message",
            let decoded = decodeSSEJSON(event.data),
            let result = try MCPJSONRPCMessage.result(from: decoded, expectedID: id, method: method) else {
        continue
      }
      AppLogger.mcp.debug(
        "[MCPHTTP] SSE result matched method=\(method, privacy: .public) id=\(id, privacy: .public)"
      )
      return result
    }

    if let event = parser.finish(),
       event.event == nil || event.event == "message",
       let decoded = decodeSSEJSON(event.data),
       let result = try MCPJSONRPCMessage.result(from: decoded, expectedID: id, method: method) {
      AppLogger.mcp.debug(
        "[MCPHTTP] SSE result matched method=\(method, privacy: .public) id=\(id, privacy: .public)"
      )
      return result
    }

    throw MCPAppDiscoveryError.invalidResponse("SSE response for \(method) did not include request id \(id).")
  }

  private func resultFromSSEBytes(
    _ bytes: URLSession.AsyncBytes,
    expectedID id: Int,
    method: String
  ) async throws -> AgentHubMCPUIJSONValue {
    var parser = MCPSSEEventParser()
    for try await line in bytes.lines {
      guard let event = parser.append(line: line),
            event.event == nil || event.event == "message",
            let decoded = decodeSSEJSON(event.data),
            let result = try MCPJSONRPCMessage.result(from: decoded, expectedID: id, method: method) else {
        continue
      }
      return result
    }

    if let event = parser.finish(),
       event.event == nil || event.event == "message",
       let decoded = decodeSSEJSON(event.data),
       let result = try MCPJSONRPCMessage.result(from: decoded, expectedID: id, method: method) {
      return result
    }

    throw MCPAppDiscoveryError.invalidResponse("SSE response for \(method) did not include request id \(id).")
  }

  private func validateStreamableHTTPResponse(
    _ response: URLResponse,
    bytes: URLSession.AsyncBytes,
    allowsLegacySSEFallback: Bool
  ) async throws -> HTTPURLResponse {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw MCPAppDiscoveryError.invalidResponse("HTTP transport returned a non-HTTP response.")
    }

    if (200...299).contains(httpResponse.statusCode)
      || (allowsLegacySSEFallback && shouldFallbackToLegacySSE(httpResponse)) {
      return httpResponse
    }

    let data = try await data(from: bytes)
    return try validateHTTPResponse(
      httpResponse,
      data: data,
      allowsLegacySSEFallback: allowsLegacySSEFallback
    )
  }

  private func validateHTTPResponse(
    _ response: URLResponse,
    data: Data,
    allowsLegacySSEFallback: Bool = false
  ) throws -> HTTPURLResponse {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw MCPAppDiscoveryError.invalidResponse("HTTP transport returned a non-HTTP response.")
    }

    if (200...299).contains(httpResponse.statusCode)
      || (allowsLegacySSEFallback && shouldFallbackToLegacySSE(httpResponse)) {
      return httpResponse
    }

    if httpResponse.statusCode == 401 {
      if let challenge = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate"),
         !challenge.isEmpty {
        throw MCPAppDiscoveryError.unsupportedAuthentication(
          "MCP server requires \(challenge) authentication. AgentHub currently supports unauthenticated HTTP/SSE MCP servers only."
        )
      }
      throw MCPAppDiscoveryError.authenticationRequired(
        "MCP server returned 401 Unauthorized. AgentHub currently supports unauthenticated HTTP/SSE MCP servers only."
      )
    }

    if httpResponse.statusCode == 403 {
      throw MCPAppDiscoveryError.authenticationRequired(
        "MCP server returned 403 Forbidden. AgentHub currently supports unauthenticated HTTP/SSE MCP servers only."
      )
    }

    let body = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
    throw MCPAppDiscoveryError.httpRequestFailed(httpResponse.statusCode, body)
  }

  private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    do {
      return try await session.data(for: request)
    } catch let error as URLError {
      throw remoteServerUnreachableError(error: error, url: request.url)
    }
  }

  private func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
    do {
      return try await session.bytes(for: request)
    } catch let error as URLError {
      throw remoteServerUnreachableError(error: error, url: request.url)
    }
  }

  private func data(from bytes: URLSession.AsyncBytes) async throws -> Data {
    var buffer: [UInt8] = []
    for try await byte in bytes {
      buffer.append(byte)
    }
    return Data(buffer)
  }

  private func remoteServerUnreachableError(error: URLError, url: URL?) -> MCPAppDiscoveryError {
    let target = url?.absoluteString ?? "remote MCP server"
    return .remoteServerUnreachable("Could not reach \(target): \(error.localizedDescription)")
  }

  private func shouldFallbackToLegacySSE(_ response: HTTPURLResponse) -> Bool {
    response.statusCode == 404 || response.statusCode == 405
  }

  private func resolveLegacyPostEndpoint(_ value: String, relativeTo endpoint: URL) throws -> URL {
    guard let url = URL(string: value, relativeTo: endpoint)?.absoluteURL else {
      throw MCPAppDiscoveryError.invalidResponse("Legacy SSE endpoint event did not contain a valid URL.")
    }
    return url
  }

  private func decodeJSON(_ data: Data) throws -> AgentHubMCPUIJSONValue {
    do {
      return try JSONDecoder().decode(AgentHubMCPUIJSONValue.self, from: data)
    } catch {
      throw MCPAppDiscoveryError.invalidResponse(error.localizedDescription)
    }
  }

  private func decodeSSEJSON(_ text: String) -> AgentHubMCPUIJSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(AgentHubMCPUIJSONValue.self, from: data)
  }

  private func contentType(from response: HTTPURLResponse) -> String {
    response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
  }

  private var endpointDescription: String {
    switch mode {
    case .streamableHTTP(let endpoint, _), .legacySSE(let endpoint):
      return redactedEndpointDescription(endpoint)
    }
  }

  private func redactedEndpointDescription(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    return components?.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")"
  }

  private func storeSessionID(from response: HTTPURLResponse) {
    guard let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !sessionID.isEmpty else {
      return
    }
    stateLock.lock()
    self.sessionID = sessionID
    stateLock.unlock()
  }

  private func currentSessionID() -> String? {
    stateLock.lock()
    let sessionID = sessionID
    stateLock.unlock()
    return sessionID
  }

  private func nextRequestID() -> Int {
    stateLock.lock()
    let id = nextID
    nextID += 1
    stateLock.unlock()
    return id
  }

  private func withTimeout<T: Sendable>(
    method: String,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(self.requestTimeoutSeconds))
        AppLogger.mcp.error(
          "[MCPHTTP] timeout method=\(method, privacy: .public) seconds=\(self.requestTimeoutSeconds, privacy: .public)"
        )
        throw MCPAppDiscoveryError.requestTimedOut(method)
      }

      do {
        guard let value = try await group.next() else {
          throw MCPAppDiscoveryError.requestTimedOut(method)
        }
        group.cancelAll()
        return value
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }
}

private struct MCPSSEEvent: Sendable, Equatable {
  let event: String?
  let data: String
  let id: String?
}

private struct MCPSSEEventParser {
  private var event: String?
  private var dataLines: [String] = []
  private var id: String?

  mutating func append(line rawLine: String) -> MCPSSEEvent? {
    let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    guard !line.isEmpty else {
      return finish()
    }
    guard !line.hasPrefix(":") else {
      return nil
    }

    let field: String
    let value: String
    if let separator = line.firstIndex(of: ":") {
      field = String(line[..<separator])
      let rawValue = String(line[line.index(after: separator)...])
      value = rawValue.hasPrefix(" ") ? String(rawValue.dropFirst()) : rawValue
    } else {
      field = line
      value = ""
    }

    switch field {
    case "event":
      if event != nil || !dataLines.isEmpty || id != nil {
        let pending = finish()
        event = value
        return pending
      }
      event = value
    case "data":
      dataLines.append(value)
    case "id":
      id = value
    default:
      break
    }
    return nil
  }

  mutating func finish() -> MCPSSEEvent? {
    guard event != nil || !dataLines.isEmpty || id != nil else {
      return nil
    }
    let current = MCPSSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id)
    event = nil
    dataLines = []
    id = nil
    return current
  }
}
