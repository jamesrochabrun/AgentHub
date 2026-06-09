import AgentHubMCPUI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("MCP App discovery service", .serialized)
struct MCPAppDiscoveryServiceTests {
  @Test("Routes tool calls to the selected MCP server")
  func routesToolCallsToSelectedServer() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let script = directory.appending(path: "fake-tool-call.sh")
    try """
    #!/bin/sh
    IFS= read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}'
    IFS= read -r line
    IFS= read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"called"}],"structuredContent":{"ok":true}}}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let service = MCPAppDiscoveryService(
      resolver: StaticMCPServerConfigurationResolver(configs: [
        MCPServerConfiguration(
          provider: .codex,
          projectPath: directory.path,
          name: "fake",
          command: "/bin/sh",
          args: [script.path],
          cwd: directory.path
        )
      ]),
      requestTimeoutSeconds: 2
    )

    let result = try await service.callTool(
      provider: .codex,
      projectPath: directory.path,
      serverName: "fake",
      name: "echo",
      arguments: .object(["message": .string("hello")])
    )

    #expect(result["structuredContent"]?["ok"] == .bool(true))
    #expect(result["content"]?.arrayValue?.first?["text"] == .string("called"))
  }

  @Test("Reuses initialized clients across tool calls")
  func reusesInitializedClientsAcrossToolCalls() async throws {
    let endpoint = try #require(URL(string: "http://localhost:9100/mcp"))
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let client = FakeMCPJSONRPCClient()
    let service = MCPAppDiscoveryService(
      resolver: StaticMCPServerConfigurationResolver(configs: [
        MCPServerConfiguration(
          provider: .claude,
          projectPath: directory.path,
          name: "remote",
          transport: .streamableHTTP(endpoint, legacySSEFallback: true)
        )
      ]),
      clientFactory: StaticMCPJSONRPCClientFactory(client: client),
      requestTimeoutSeconds: 2
    )

    _ = try await service.callTool(
      provider: .claude,
      projectPath: directory.path,
      serverName: "remote",
      name: "echo",
      arguments: .object([:])
    )
    let result = try await service.callTool(
      provider: .claude,
      projectPath: directory.path,
      serverName: "remote",
      name: "echo",
      arguments: .object([:])
    )

    // The pool initializes once and reuses the same client for both calls.
    #expect(result["structuredContent"]?["ok"] == .bool(true))
    #expect(await client.requestedMethods() == [
      "initialize",
      "tools/call",
      "tools/call"
    ])
    #expect(client.startCallCount() == 1)
    #expect(client.closeCallCount() == 0)
  }

  @Test("Idle timeout closes pooled MCP clients before reuse")
  func idleTimeoutClosesPooledClientsBeforeReuse() async throws {
    let endpoint = try #require(URL(string: "http://localhost:9300/mcp"))
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let factory = RecordingMCPJSONRPCClientFactory()
    let service = MCPAppDiscoveryService(
      resolver: StaticMCPServerConfigurationResolver(configs: [
        MCPServerConfiguration(
          provider: .claude,
          projectPath: directory.path,
          name: "remote",
          transport: .streamableHTTP(endpoint, legacySSEFallback: true)
        )
      ]),
      clientFactory: factory,
      requestTimeoutSeconds: 2,
      idleTimeoutSeconds: 0.001
    )

    _ = try await service.callTool(
      provider: .claude,
      projectPath: directory.path,
      serverName: "remote",
      name: "echo",
      arguments: .object([:])
    )
    let first = try #require(factory.clients.first)
    try await Task.sleep(for: .milliseconds(10))
    _ = try await service.callTool(
      provider: .claude,
      projectPath: directory.path,
      serverName: "remote",
      name: "echo",
      arguments: .object([:])
    )

    #expect(factory.clients.count == 2)
    #expect(first.closeCallCount() >= 1)
  }

  @Test("Resolver maps URL configs to HTTP and SSE transports")
  func resolverMapsURLConfigsToHTTPTransports() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let claudeConfig = directory.appending(path: "claude.json")
    try """
    {
      "mcpServers": {
        "remote": {
          "type": "http",
          "url": "http://localhost:9000/mcp"
        },
        "legacy": {
          "type": "sse",
          "url": "http://localhost:9001/sse"
        }
      }
    }
    """.write(to: claudeConfig, atomically: true, encoding: .utf8)

    let resolver = DefaultMCPServerConfigurationResolver(
      claudeConfigPath: claudeConfig.path,
      codexConfigPath: directory.appending(path: "missing.toml").path
    )

    let configs = await resolver.serverConfigurations(provider: .claude, projectPath: directory.path)
    let remote = try #require(configs.first { $0.name == "remote" })
    let legacy = try #require(configs.first { $0.name == "legacy" })

    if case .streamableHTTP(let endpoint, let legacySSEFallback) = remote.transport {
      #expect(endpoint.absoluteString == "http://localhost:9000/mcp")
      #expect(legacySSEFallback)
      #expect(remote.command == nil)
    } else {
      Issue.record("Expected remote config to use streamable HTTP transport")
    }

    if case .sse(let endpoint) = legacy.transport {
      #expect(endpoint.absoluteString == "http://localhost:9001/sse")
      #expect(legacy.command == nil)
    } else {
      Issue.record("Expected legacy config to use SSE transport")
    }
  }

  @Test("Resolver parses stdio args env cwd and HTTP variants")
  func resolverParsesStdioArgsEnvCWDAndHTTPVariants() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let claudeConfig = directory.appending(path: "claude.json")
    try """
    {
      "mcpServers": {
        "stdio": {
          "command": "node",
          "args": ["server.js", "--flag"],
          "env": { "API_BASE": "http://localhost:3000" },
          "cwd": "/tmp/mcp-stdio"
        },
        "streamable": {
          "transportType": "streamable-http",
          "endpoint": "https://mcp.example.com/mcp"
        },
        "autodetected": {
          "serverURL": "https://mcp.example.com/auto"
        },
        "authenticated": {
          "type": "http",
          "url": "https://mcp.example.com/private",
          "headers": { "Authorization": "Bearer secret" }
        }
      }
    }
    """.write(to: claudeConfig, atomically: true, encoding: .utf8)

    let codexConfig = directory.appending(path: "config.toml")
    try """
    [mcp_servers.codex_stdio]
    command = "python"
    args = ["server.py", "--debug"]
    cwd = "/tmp/codex-mcp"
    env = { API_BASE = "http://localhost:3001" }

    [mcp_servers.codex_stdio.env]
    EXTRA = "1"

    [mcp_servers.codex_remote]
    type = "sse"
    uri = "https://mcp.example.com/events"
    """.write(to: codexConfig, atomically: true, encoding: .utf8)

    let resolver = DefaultMCPServerConfigurationResolver(
      claudeConfigPath: claudeConfig.path,
      codexConfigPath: codexConfig.path
    )

    let claudeConfigs = await resolver.serverConfigurations(provider: .claude, projectPath: directory.path)
    let stdio = try #require(claudeConfigs.first { $0.name == "stdio" })
    #expect(stdio.transport == .stdio)
    #expect(stdio.command == "node")
    #expect(stdio.args == ["server.js", "--flag"])
    #expect(stdio.env["API_BASE"] == "http://localhost:3000")
    #expect(stdio.cwd == "/tmp/mcp-stdio")

    let streamable = try #require(claudeConfigs.first { $0.name == "streamable" })
    if case .streamableHTTP(let endpoint, let legacySSEFallback) = streamable.transport {
      #expect(endpoint.absoluteString == "https://mcp.example.com/mcp")
      #expect(legacySSEFallback)
    } else {
      Issue.record("Expected streamable HTTP transport")
    }

    let autodetected = try #require(claudeConfigs.first { $0.name == "autodetected" })
    if case .streamableHTTP(let endpoint, _) = autodetected.transport {
      #expect(endpoint.absoluteString == "https://mcp.example.com/auto")
    } else {
      Issue.record("Expected URL-only config to use streamable HTTP")
    }

    let authenticated = try #require(claudeConfigs.first { $0.name == "authenticated" })
    if case .unsupportedAuthentication(let message) = authenticated.transport {
      #expect(message.contains("Authenticated remote MCP servers"))
    } else {
      Issue.record("Expected authenticated HTTP config to be rejected")
    }

    let codexConfigs = await resolver.serverConfigurations(provider: .codex, projectPath: directory.path)
    let codexStdio = try #require(codexConfigs.first { $0.name == "codex_stdio" })
    #expect(codexStdio.command == "python")
    #expect(codexStdio.args == ["server.py", "--debug"])
    #expect(codexStdio.cwd == "/tmp/codex-mcp")
    #expect(codexStdio.env["API_BASE"] == "http://localhost:3001")
    #expect(codexStdio.env["EXTRA"] == "1")

    let codexRemote = try #require(codexConfigs.first { $0.name == "codex_remote" })
    if case .sse(let endpoint) = codexRemote.transport {
      #expect(endpoint.absoluteString == "https://mcp.example.com/events")
    } else {
      Issue.record("Expected Codex remote config to use SSE")
    }
  }

  @Test("HTTP client reads JSON responses and reuses session id")
  func httpClientReadsJSONResponsesAndReusesSessionID() async throws {
    let endpoint = try #require(URL(string: "https://mcp.test/\(UUID().uuidString)/mcp"))
    MockURLProtocol.reset()
    MockURLProtocol.setHandler(for: endpoint.absoluteString) { request in
      let body = requestBody(from: request)
      let decoded = try JSONDecoder().decode(AgentHubMCPUIJSONValue.self, from: body)
      let id = decoded["id"] ?? .number(0)
      guard let response = HTTPURLResponse(
        url: endpoint,
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
          "Content-Type": "application/json",
          "Mcp-Session-Id": "session-1"
        ]
      ) else {
        throw URLError(.badServerResponse)
      }
      let data = try JSONEncoder().encode(AgentHubMCPUIJSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": .object(["ok": .bool(true)])
      ]))
      return (response, data)
    }

    let client = try MCPHTTPJSONRPCClient(
      config: MCPServerConfiguration(
        provider: .claude,
        projectPath: "/project",
        name: "remote",
        transport: .streamableHTTP(endpoint, legacySSEFallback: true)
      ),
      requestTimeoutSeconds: 2,
      session: mockURLSession()
    )

    let initialized = try await client.request(method: "initialize", params: .object([:]))
    let tools = try await client.request(method: "tools/list", params: .object([:]))
    let requests = MockURLProtocol.requests(for: endpoint.absoluteString)

    #expect(initialized["ok"] == .bool(true))
    #expect(tools["ok"] == .bool(true))
    #expect(requests.count == 2)
    #expect(requests.last?.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-1")
    #expect(requests.last?.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
  }

  @Test("HTTP client reads streamable HTTP SSE responses")
  func httpClientReadsStreamableHTTPSSEResponses() async throws {
    let endpoint = try #require(URL(string: "https://mcp.test/\(UUID().uuidString)/mcp"))
    MockURLProtocol.reset()
    MockURLProtocol.setHandler(for: endpoint.absoluteString) { request in
      let body = requestBody(from: request)
      let decoded = try JSONDecoder().decode(AgentHubMCPUIJSONValue.self, from: body)
      let id = decoded["id"] ?? .number(0)
      guard let response = HTTPURLResponse(
        url: endpoint,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/event-stream"]
      ) else {
        throw URLError(.badServerResponse)
      }
      let payload = try JSONEncoder().encode(AgentHubMCPUIJSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": .object(["streamed": .bool(true)])
      ]))
      let data = Data("event: message\ndata: \(String(data: payload, encoding: .utf8) ?? "{}")\n\n".utf8)
      return (response, data)
    }

    let client = try MCPHTTPJSONRPCClient(
      config: MCPServerConfiguration(
        provider: .claude,
        projectPath: "/project",
        name: "remote",
        transport: .streamableHTTP(endpoint, legacySSEFallback: true)
      ),
      requestTimeoutSeconds: 2,
      session: mockURLSession()
    )

    let result = try await client.request(method: "tools/list", params: .object([:]))
    #expect(result["streamed"] == .bool(true))
  }

  @Test("HTTP client falls back to legacy SSE")
  func httpClientFallsBackToLegacySSE() async throws {
    let endpoint = try #require(URL(string: "https://mcp.test/\(UUID().uuidString)/mcp"))
    let postEndpoint = try #require(URL(string: "https://mcp.test/\(UUID().uuidString)/messages"))
    MockURLProtocol.reset()
    MockURLProtocol.setHandler(for: endpoint.absoluteString) { request in
      if request.httpMethod == "POST" {
        guard let response = HTTPURLResponse(
          url: endpoint,
          statusCode: 404,
          httpVersion: nil,
          headerFields: ["Content-Type": "text/plain"]
        ) else {
          throw URLError(.badServerResponse)
        }
        return (response, Data())
      }

      let payload = try JSONEncoder().encode(AgentHubMCPUIJSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": .number(1),
        "result": .object(["legacy": .bool(true)])
      ]))
      let text = """
      event: endpoint
      data: \(postEndpoint.absoluteString)

      event: message
      data: \(String(data: payload, encoding: .utf8) ?? "{}")

      """
      guard let response = HTTPURLResponse(
        url: endpoint,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/event-stream"]
      ) else {
        throw URLError(.badServerResponse)
      }
      return (response, Data(text.utf8))
    }
    MockURLProtocol.setHandler(for: postEndpoint.absoluteString) { _ in
      guard let response = HTTPURLResponse(
        url: postEndpoint,
        statusCode: 202,
        httpVersion: nil,
        headerFields: [:]
      ) else {
        throw URLError(.badServerResponse)
      }
      return (response, Data())
    }

    let client = try MCPHTTPJSONRPCClient(
      config: MCPServerConfiguration(
        provider: .claude,
        projectPath: "/project",
        name: "remote",
        transport: .streamableHTTP(endpoint, legacySSEFallback: true)
      ),
      requestTimeoutSeconds: 2,
      session: mockURLSession()
    )

    let result = try await client.request(method: "tools/list", params: .object([:]))
    #expect(result["legacy"] == .bool(true))
    #expect(MockURLProtocol.requests(for: endpoint.absoluteString).map { $0.httpMethod ?? "" } == ["POST", "GET"])
    #expect(MockURLProtocol.requests(for: postEndpoint.absoluteString).count == 1)
  }

  @Test("HTTP client reports unsupported authentication")
  func httpClientReportsUnsupportedAuthentication() async throws {
    let endpoint = try #require(URL(string: "https://mcp.test/\(UUID().uuidString)/mcp"))
    MockURLProtocol.reset()
    MockURLProtocol.setHandler(for: endpoint.absoluteString) { _ in
      guard let response = HTTPURLResponse(
        url: endpoint,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["WWW-Authenticate": "Bearer"]
      ) else {
        throw URLError(.badServerResponse)
      }
      return (response, Data())
    }

    let client = try MCPHTTPJSONRPCClient(
      config: MCPServerConfiguration(
        provider: .claude,
        projectPath: "/project",
        name: "remote",
        transport: .streamableHTTP(endpoint, legacySSEFallback: true)
      ),
      requestTimeoutSeconds: 2,
      session: mockURLSession()
    )

    await #expect(throws: MCPAppDiscoveryError.self) {
      _ = try await client.request(method: "initialize", params: .object([:]))
    }
  }

  @Test("HTTP client reports unreachable remote servers")
  func httpClientReportsUnreachableRemoteServers() async throws {
    let endpoint = try #require(URL(string: "https://mcp.test/\(UUID().uuidString)/mcp"))
    MockURLProtocol.reset()
    let client = try MCPHTTPJSONRPCClient(
      config: MCPServerConfiguration(
        provider: .claude,
        projectPath: "/project",
        name: "remote",
        transport: .streamableHTTP(endpoint, legacySSEFallback: true)
      ),
      requestTimeoutSeconds: 2,
      session: mockURLSession()
    )

    await #expect(throws: MCPAppDiscoveryError.self) {
      _ = try await client.request(method: "initialize", params: .object([:]))
    }
  }
}

private struct StaticMCPServerConfigurationResolver: MCPServerConfigurationResolverProtocol {
  let configs: [MCPServerConfiguration]

  func serverConfigurations(
    provider: SessionProviderKind,
    projectPath: String
  ) async -> [MCPServerConfiguration] {
    configs.filter { $0.provider == provider && $0.projectPath == projectPath }
  }
}

private struct StaticMCPJSONRPCClientFactory: MCPJSONRPCClientFactoryProtocol {
  let client: any MCPJSONRPCClientProtocol

  func makeClient(
    config: MCPServerConfiguration,
    requestTimeoutSeconds: TimeInterval
  ) throws -> any MCPJSONRPCClientProtocol {
    client
  }
}

private final class RecordingMCPJSONRPCClientFactory: MCPJSONRPCClientFactoryProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var clients: [FakeMCPJSONRPCClient] = []

  func makeClient(
    config: MCPServerConfiguration,
    requestTimeoutSeconds: TimeInterval
  ) throws -> any MCPJSONRPCClientProtocol {
    let client = FakeMCPJSONRPCClient()
    lock.lock()
    clients.append(client)
    lock.unlock()
    return client
  }
}

private final class FakeMCPClientRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var starts = 0
  private var closes = 0

  func recordStart() {
    lock.lock()
    starts += 1
    lock.unlock()
  }

  func recordClose() {
    lock.lock()
    closes += 1
    lock.unlock()
  }

  func startCallCount() -> Int {
    lock.lock()
    let value = starts
    lock.unlock()
    return value
  }

  func closeCallCount() -> Int {
    lock.lock()
    let value = closes
    lock.unlock()
    return value
  }
}

private actor FakeMCPJSONRPCClient: MCPJSONRPCClientProtocol {
  private let recorder = FakeMCPClientRecorder()
  private var methods: [String] = []

  nonisolated func start() throws {
    recorder.recordStart()
  }

  func request(
    method: String,
    params: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    methods.append(method)
    switch method {
    case "initialize":
      return .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:])])
    case "tools/call":
      return .object([
        "content": .array([.object(["type": .string("text"), "text": .string("called")])]),
        "structuredContent": .object(["ok": .bool(true)])
      ])
    case "tools/list":
      return .object([
        "tools": .array([
          .object([
            "name": .string("show_dashboard"),
            "_meta": .object([
              "ui": .object([
                "resourceUri": .string("ui://remote/dashboard"),
                "title": .string("Remote")
              ])
            ])
          ])
        ])
      ])
    case "resources/list":
      return .object(["resources": .array([])])
    case "resources/read":
      return .object([
        "contents": .array([
          .object([
            "uri": .string("ui://remote/dashboard"),
            "mimeType": .string(AgentHubMCPUIResource.htmlAppMimeType),
            "text": .string("<main>Remote</main>")
          ])
        ])
      ])
    default:
      return .object([:])
    }
  }

  func notify(method: String, params: AgentHubMCPUIJSONValue?) async throws {}

  nonisolated func close() {
    recorder.recordClose()
  }

  func requestedMethods() -> [String] {
    methods
  }

  nonisolated func startCallCount() -> Int {
    recorder.startCallCount()
  }

  nonisolated func closeCallCount() -> Int {
    recorder.closeCallCount()
  }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  private static let lock = NSLock()
  private static var handlers: [String: Handler] = [:]
  private static var seenRequests: [String: [URLRequest]] = [:]

  static func reset() {
    lock.lock()
    handlers = [:]
    seenRequests = [:]
    lock.unlock()
  }

  static func setHandler(for url: String, handler: @escaping Handler) {
    lock.lock()
    handlers[url] = handler
    lock.unlock()
  }

  static func requests(for url: String) -> [URLRequest] {
    lock.lock()
    let requests = seenRequests[url] ?? []
    lock.unlock()
    return requests
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let key = request.url?.absoluteString ?? ""
    let handler: Handler?
    Self.lock.lock()
    Self.seenRequests[key, default: []].append(request)
    handler = Self.handlers[key]
    Self.lock.unlock()

    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func mockURLSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func requestBody(from request: URLRequest) -> Data {
  if let body = request.httpBody {
    return body
  }
  guard let stream = request.httpBodyStream else {
    return Data()
  }

  stream.open()
  defer { stream.close() }

  var data = Data()
  let bufferSize = 1024
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
  defer { buffer.deallocate() }

  while stream.hasBytesAvailable {
    let count = stream.read(buffer, maxLength: bufferSize)
    guard count > 0 else { break }
    data.append(buffer, count: count)
  }
  return data
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "agenthub_mcp_app_discovery_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
