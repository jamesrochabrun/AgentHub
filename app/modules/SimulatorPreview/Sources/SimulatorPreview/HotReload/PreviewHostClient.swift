import Foundation

// MARK: - Models

/// One discovered preview-bearing type from the preview host's manifest
/// (`metadata.json` written by SnapshotPreviews on `GET /file`).
public struct PreviewHostPreviewType: Equatable, Sendable, Identifiable {
  /// Mangled-ish runtime type name — also the render-request key.
  public let typeName: String
  /// "MyModule/HomeView.swift:HomeView" style name when available.
  public let displayName: String?
  public let numPreviews: Int

  public var id: String { typeName }

  public init(typeName: String, displayName: String?, numPreviews: Int) {
    self.typeName = typeName
    self.displayName = displayName
    self.numPreviews = numPreviews
  }

  /// Render-request ids: `previewId` is the 0-based index into the type's
  /// previews (`"0"` for `#Preview` registries, which hold one preview each).
  public var previewIds: [String] {
    (0..<max(numPreviews, 0)).map(String.init)
  }

  /// "HomeView" from "MyModule/HomeView.swift:HomeView", else a cleaned-up
  /// type name suitable for a card label.
  public var cardTitle: String {
    if let displayName {
      if let colon = displayName.lastIndex(of: ":") {
        let suffix = displayName[displayName.index(after: colon)...]
        if !suffix.isEmpty { return String(suffix) }
      }
      let file = (displayName as NSString).lastPathComponent
      if file.hasSuffix(".swift") { return String(file.dropLast(".swift".count)) }
      return displayName
    }
    return typeName
  }

  /// Module name ("MyModule" from "MyModule/HomeView.swift:HomeView").
  public var moduleName: String? {
    guard let displayName,
          let slash = displayName.firstIndex(of: "/")
    else { return nil }
    let module = displayName[..<slash]
    return module.isEmpty ? nil : String(module)
  }

  /// "HomeView.swift" from "MyModule/HomeView.swift:Dark Mode" — `#Preview`
  /// registries carry their source fileID in the display name.
  public var sourceFileName: String? {
    guard let displayName else { return nil }
    let withoutPreviewName = displayName[
      ..<(displayName.firstIndex(of: ":") ?? displayName.endIndex)]
    let file = (String(withoutPreviewName) as NSString).lastPathComponent
    return file.hasSuffix(".swift") ? file : nil
  }

  /// Whether this preview's source is one of `fileNames` (e.g. the files
  /// edited this session). `#Preview` registries match exactly via their
  /// fileID; `PreviewProvider` types match by the `Foo_Previews` ↔
  /// `Foo.swift` naming convention.
  public func matchesSource(fileNames: [String]) -> Bool {
    if let sourceFileName {
      return fileNames.contains(sourceFileName)
    }
    let lastTypeComponent = typeName.split(separator: ".").last.map(String.init)
      ?? typeName
    guard lastTypeComponent.hasSuffix("_Previews") else { return false }
    let base = String(lastTypeComponent.dropLast("_Previews".count))
    return fileNames.contains("\(base).swift")
  }
}

/// Result of rendering one preview.
public struct PreviewHostRenderResult: Equatable, Sendable {
  public let displayName: String?
  /// PNG bytes of the rendered preview.
  public let imageData: Data?
  /// Pixels-per-point of the render (the host renders at device scale so
  /// the image stays crisp). Display at pixelSize / scale points — never
  /// larger, or the bitmap gets upscaled and blurs.
  public let scale: Double?
  public let errorMessage: String?

  public init(
    displayName: String?,
    imageData: Data?,
    scale: Double? = nil,
    errorMessage: String?
  ) {
    self.displayName = displayName
    self.imageData = imageData
    self.scale = scale
    self.errorMessage = errorMessage
  }
}

public enum PreviewHostClientError: LocalizedError, Equatable {
  case serverUnreachable
  /// Something is listening but did not answer in time — unlike
  /// `.serverUnreachable`, retrying immediately is unlikely to help.
  case timedOut
  case malformedResponse(detail: String)

  public var errorDescription: String? {
    switch self {
    case .serverUnreachable:
      return "The preview host isn't running. Build & run with previews enabled."
    case .timedOut:
      return "The preview host is not responding (request timed out)."
    case .malformedResponse(let detail):
      return "Unexpected preview host response: \(detail)"
    }
  }
}

// MARK: - Decoding (pure, unit-tested)

/// Decodes SnapshotPreviews' loose JSON payloads.
public enum PreviewHostDecoding {

  /// `metadata.json`: array of `{typeName, numPreviews, displayName?, …}`.
  public static func decodeManifest(_ data: Data) throws -> [PreviewHostPreviewType] {
    guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      throw PreviewHostClientError.malformedResponse(detail: "manifest is not an array")
    }
    return array.compactMap { entry in
      guard let typeName = entry["typeName"] as? String else { return nil }
      return PreviewHostPreviewType(
        typeName: typeName,
        displayName: entry["displayName"] as? String,
        numPreviews: entry["numPreviews"] as? Int ?? 1
      )
    }
  }

  /// `GET /display/...` response: `{displayName?, imagePath?, error?}`.
  /// The image is written to a path on the shared simulator filesystem;
  /// `readFile` abstracts the disk read for tests.
  public static func decodeRender(
    _ data: Data,
    readFile: (String) -> Data?
  ) throws -> PreviewHostRenderResult {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw PreviewHostClientError.malformedResponse(detail: "render response is not an object")
    }
    let imagePath = object["imagePath"] as? String
    return PreviewHostRenderResult(
      displayName: object["displayName"] as? String,
      imageData: imagePath.flatMap(readFile),
      scale: object["scale"] as? Double,
      errorMessage: object["error"] as? String
    )
  }
}

// MARK: - Client

public protocol PreviewHostClientProtocol: Sendable {
  /// Asks the host to re-discover previews and returns the manifest.
  func listPreviews() async throws -> [PreviewHostPreviewType]
  /// Renders one preview to PNG data.
  func render(typeName: String, previewId: String) async throws -> PreviewHostRenderResult
}

/// Talks to the inserted preview host's HTTP server. The simulator shares
/// the host's loopback interface and filesystem, so the server is reachable
/// locally and returned image paths are directly readable.
///
/// FlyingFox's `.loopback` binds the IPv6 loopback (`::1`), so that address
/// is primary; `127.0.0.1` is kept as a fallback in case a future pin binds
/// IPv4 instead.
public struct PreviewHostHTTPClient: PreviewHostClientProtocol {

  /// Default port shared with the generated preview host — used when a
  /// launch didn't carry a per-device port (see `PreviewHostPortAllocator`).
  public static let port = HotReloadHostPackage.previewHostDefaultPort

  private let baseURLs: [URL]
  private let session: URLSession

  public init(port: Int = PreviewHostHTTPClient.port) {
    baseURLs = [
      URL(string: "http://[::1]:\(port)")!,
      URL(string: "http://127.0.0.1:\(port)")!,
    ]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    session = URLSession(configuration: configuration)
  }

  public func listPreviews() async throws -> [PreviewHostPreviewType] {
    // `GET /file` re-runs discovery, rewrites metadata.json inside the app's
    // results directory, and returns that directory's path as the body.
    let body = try await get(path: "/file")
    guard let resultsDir = String(data: body, encoding: .utf8),
          !resultsDir.isEmpty
    else {
      throw PreviewHostClientError.malformedResponse(detail: "empty results path")
    }
    let manifestURL = URL(fileURLWithPath: resultsDir)
      .appendingPathComponent("metadata.json")
    guard let manifest = try? Data(contentsOf: manifestURL) else {
      throw PreviewHostClientError.malformedResponse(
        detail: "manifest missing at \(manifestURL.path)")
    }
    return try PreviewHostDecoding.decodeManifest(manifest)
  }

  public func render(
    typeName: String, previewId: String
  ) async throws -> PreviewHostRenderResult {
    let escapedType = typeName.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed) ?? typeName
    let body = try await get(path: "/display/\(escapedType)/\(previewId)")
    return try PreviewHostDecoding.decodeRender(body) { path in
      try? Data(contentsOf: URL(fileURLWithPath: path))
    }
  }

  private func get(path: String) async throws -> Data {
    var lastError: PreviewHostClientError = .serverUnreachable
    for baseURL in baseURLs {
      guard let url = URL(string: path, relativeTo: baseURL) else {
        throw PreviewHostClientError.malformedResponse(detail: "bad path \(path)")
      }
      do {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          throw PreviewHostClientError.malformedResponse(
            detail: "status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
      } catch let error as PreviewHostClientError {
        lastError = error
      } catch let error as URLError where error.code == .timedOut {
        lastError = .timedOut
      } catch {
        lastError = .serverUnreachable
      }
    }
    throw lastError
  }
}
