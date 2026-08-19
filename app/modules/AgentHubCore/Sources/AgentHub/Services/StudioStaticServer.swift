import Foundation
import Network

public protocol StudioStaticServing: Sendable {
  /// Starts the server if needed and returns its base URL (`http://127.0.0.1:{port}/`).
  func start() async throws -> URL
  func stop() async
}

/// A tiny loopback HTTP/1.1 file server for Studio documents.
///
/// In-process rather than `python3 -m http.server`: Studio content is AgentHub's
/// own directory, so there is no child process to track and reap, no python
/// dependency, and no readiness heuristics — and `Cache-Control: no-store` makes
/// re-file reload free. GET/HEAD only, bound to `127.0.0.1`, serves only under
/// `rootURL`, refuses anything that escapes it. Studio content is unreviewed
/// agent-generated HTML: it must not be reachable off the machine, and this must
/// never become a file-read primitive.
public actor StudioStaticServer: StudioStaticServing {
  public enum ServerError: Error, Equatable {
    case failedToStart(String)
  }

  public let rootURL: URL
  private var listener: NWListener?
  private var baseURL: URL?
  private var startContinuations: [CheckedContinuation<URL, Error>] = []
  private let queue = DispatchQueue(label: "com.agenthub.studio-static-server")

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  public func start() async throws -> URL {
    if let baseURL { return baseURL }
    if listener != nil {
      return try await withCheckedThrowingContinuation { continuation in
        startContinuations.append(continuation)
      }
    }

    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw ServerError.failedToStart(error.localizedDescription)
    }
    self.listener = listener

    return try await withCheckedThrowingContinuation { continuation in
      startContinuations.append(continuation)

      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        Task { await self.handleListenerState(state) }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        Task { await self.handle(connection) }
      }
      listener.start(queue: queue)
    }
  }

  public func stop() async {
    listener?.cancel()
    listener = nil
    baseURL = nil
    let waiting = startContinuations
    startContinuations.removeAll()
    for continuation in waiting {
      continuation.resume(throwing: ServerError.failedToStart("Server stopped."))
    }
  }

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      guard let port = listener?.port?.rawValue else { return }
      let url = URL(string: "http://127.0.0.1:\(port)/")!
      baseURL = url
      let waiting = startContinuations
      startContinuations.removeAll()
      for continuation in waiting { continuation.resume(returning: url) }
    case .failed(let error):
      listener?.cancel()
      listener = nil
      baseURL = nil
      let waiting = startContinuations
      startContinuations.removeAll()
      for continuation in waiting {
        continuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
      }
    case .cancelled:
      baseURL = nil
    default:
      break
    }
  }

  // MARK: - Connections

  private func handle(_ connection: NWConnection) {
    let root = rootURL
    let handler = ConnectionHandler(connection: connection, rootURL: root)
    connection.stateUpdateHandler = { state in
      if case .ready = state { handler.receiveRequest() }
    }
    connection.start(queue: queue)
  }

  /// One request per connection; the response always closes it.
  private final class ConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let rootURL: URL
    private var buffer = Data()

    init(connection: NWConnection, rootURL: URL) {
      self.connection = connection
      self.rootURL = rootURL
    }

    func receiveRequest() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
        if let data { buffer.append(data) }
        if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
          let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
          respond(to: head)
          return
        }
        if error != nil || isComplete || buffer.count > 65_536 {
          connection.cancel()
          return
        }
        receiveRequest()
      }
    }

    private func respond(to head: String) {
      let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
      let response = StudioStaticServer.response(forRequestLine: requestLine, rootURL: rootURL)
      connection.send(content: response, completion: .contentProcessed { [connection] _ in
        connection.cancel()
      })
    }
  }

  // MARK: - Request handling (pure, testable)

  struct Response: Equatable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data
    let includeBody: Bool

    var data: Data {
      var head = "HTTP/1.1 \(status) \(reason)\r\n"
      head += "Content-Type: \(contentType)\r\n"
      head += "Content-Length: \(body.count)\r\n"
      head += "Cache-Control: no-store\r\n"
      head += "X-Content-Type-Options: nosniff\r\n"
      head += "Connection: close\r\n\r\n"
      var data = Data(head.utf8)
      if includeBody { data.append(body) }
      return data
    }
  }

  static func response(forRequestLine line: String, rootURL: URL) -> Data {
    resolve(requestLine: line, rootURL: rootURL).data
  }

  static func resolve(requestLine line: String, rootURL: URL) -> Response {
    let parts = line.split(separator: " ")
    guard parts.count >= 2 else {
      return Response(status: 400, reason: "Bad Request", contentType: "text/plain", body: Data("Bad request".utf8), includeBody: true)
    }
    let method = String(parts[0])
    guard method == "GET" || method == "HEAD" else {
      return Response(status: 405, reason: "Method Not Allowed", contentType: "text/plain", body: Data("Method not allowed".utf8), includeBody: true)
    }
    let includeBody = method == "GET"

    guard let fileURL = fileURL(forRequestPath: String(parts[1]), rootURL: rootURL) else {
      return Response(status: 404, reason: "Not Found", contentType: "text/plain", body: Data("Not found".utf8), includeBody: includeBody)
    }
    guard let body = try? Data(contentsOf: fileURL) else {
      return Response(status: 404, reason: "Not Found", contentType: "text/plain", body: Data("Not found".utf8), includeBody: includeBody)
    }
    return Response(
      status: 200,
      reason: "OK",
      contentType: contentType(forExtension: fileURL.pathExtension),
      body: body,
      includeBody: includeBody
    )
  }

  /// Maps a request path to a file strictly inside `rootURL`, or nil.
  static func fileURL(forRequestPath rawPath: String, rootURL: URL) -> URL? {
    var path = rawPath
    if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
    if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
    guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/") else { return nil }
    guard !decoded.contains("\0") else { return nil }

    let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) else { return nil }

    var url = rootURL.standardizedFileURL
    for component in components {
      url.appendPathComponent(component)
    }
    var isDirectory: ObjCBool = false
    if decoded.hasSuffix("/") || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
      url.appendPathComponent("index.html")
    }
    let resolved = url.standardizedFileURL
    let rootPath = rootURL.standardizedFileURL.path.hasSuffix("/") ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/"
    guard resolved.path.hasPrefix(rootPath) else { return nil }
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
    return resolved
  }

  static func contentType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "json", "map": return "application/json; charset=utf-8"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "ico": return "image/x-icon"
    case "woff2": return "font/woff2"
    case "woff": return "font/woff"
    case "ttf": return "font/ttf"
    case "otf": return "font/otf"
    case "mp4": return "video/mp4"
    case "webm": return "video/webm"
    case "txt", "md": return "text/plain; charset=utf-8"
    default: return "application/octet-stream"
    }
  }
}
