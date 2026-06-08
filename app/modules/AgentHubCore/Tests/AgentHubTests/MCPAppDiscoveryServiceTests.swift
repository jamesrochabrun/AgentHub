import AgentHubMCPUI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("MCP App discovery service", .serialized)
struct MCPAppDiscoveryServiceTests {
  @Test("Discovers MCP app resources from a fake stdio server")
  func discoversResourcesFromFakeStdioServer() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let script = directory.appending(path: "fake-mcp.sh")
    try """
    #!/bin/sh
    IFS= read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}'
    IFS= read -r line
    IFS= read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"show_dashboard","_meta":{"ui":{"resourceUri":"ui://fake/dashboard","title":"Dashboard","csp":{"connect_domains":["https://api.example.com"],"resource_domains":["https://cdn.example.com"]}}}}]}}'
    IFS= read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"resources":[]}}'
    IFS= read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":4,"result":{"contents":[{"uri":"ui://fake/dashboard","mimeType":"text/html;profile=mcp-app","text":"<main>Dashboard</main>"}]}}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let service = MCPAppDiscoveryService(
      resolver: StaticMCPServerConfigurationResolver(configs: [
        MCPServerConfiguration(
          provider: .claude,
          projectPath: directory.path,
          name: "fake",
          command: "/bin/sh",
          args: [script.path],
          cwd: directory.path
        )
      ]),
      requestTimeoutSeconds: 2
    )

    let resources = await service.discoverResources(
      provider: .claude,
      projectPath: directory.path,
      forceRefresh: true
    )

    let resource = try #require(resources.first)
    #expect(resource.serverName == "fake")
    #expect(resource.resource.uri == "ui://fake/dashboard")
    #expect(resource.title == "Dashboard")
    #expect(resource.resource.text == "<main>Dashboard</main>")
    #expect(resource.resource.metadata.csp.connectDomains == ["https://api.example.com"])
  }

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

  @Test("Discovers resources through injected HTTP transport client")
  func discoversResourcesThroughHTTPTransportClient() async throws {
    let endpoint = try #require(URL(string: "http://localhost:9000/mcp"))
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let client = FakeMCPJSONRPCClient()
    let service = MCPAppDiscoveryService(
      resolver: StaticMCPServerConfigurationResolver(configs: [
        MCPServerConfiguration(
          provider: .codex,
          projectPath: directory.path,
          name: "remote",
          transport: .streamableHTTP(endpoint, legacySSEFallback: true)
        )
      ]),
      clientFactory: StaticMCPJSONRPCClientFactory(client: client),
      requestTimeoutSeconds: 2
    )

    let resources = await service.discoverResources(
      provider: .codex,
      projectPath: directory.path,
      forceRefresh: true
    )

    let resource = try #require(resources.first)
    #expect(resource.serverName == "remote")
    #expect(resource.resource.uri == "ui://remote/dashboard")
    #expect(resource.resource.text == "<main>Remote</main>")
    #expect(await client.requestedMethods() == [
      "initialize",
      "tools/list",
      "resources/list",
      "resources/read"
    ])
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

private actor FakeMCPJSONRPCClient: MCPJSONRPCClientProtocol {
  private var methods: [String] = []

  nonisolated func start() throws {}

  func request(
    method: String,
    params: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    methods.append(method)
    switch method {
    case "initialize":
      return .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:])])
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

  nonisolated func close() {}

  func requestedMethods() -> [String] {
    methods
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
