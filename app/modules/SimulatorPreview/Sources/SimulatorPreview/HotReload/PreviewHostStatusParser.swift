import Foundation

/// Parses the generated preview host's structured status lines from the
/// app's console into `PreviewHostStatus` values.
///
/// The host prints exactly these shapes (pinned by the artifact-store tests
/// against the generated source — keep them in sync):
///
///     AGENTHUB_PREVIEW_HOST: waiting reason=app-not-active
///     AGENTHUB_PREVIEW_HOST: listening port=38712
///     AGENTHUB_PREVIEW_HOST: unsupported reason=ios-version
///     AGENTHUB_PREVIEW_HOST: failed reason=port-in-use port=38712
///     AGENTHUB_PREVIEW_HOST: failed reason=server-error detail=<one line>
public struct PreviewHostStatusParser: Sendable {

  public static let linePrefix = "AGENTHUB_PREVIEW_HOST: "

  public init() {}

  public func parse(line: String) -> PreviewHostStatus? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(Self.linePrefix) else { return nil }
    let payload = String(trimmed.dropFirst(Self.linePrefix.count))
    let fields = Self.fields(of: payload)

    switch payload.split(separator: " ").first.map(String.init) {
    case "waiting":
      return .waitingForForeground
    case "listening":
      guard let port = fields["port"].flatMap(Int.init) else { return nil }
      return .listening(port: port)
    case "unsupported":
      return .failed(
        reason: .unsupportedOSVersion,
        detail: "SwiftUI previews require an iOS 16 or later simulator."
      )
    case "failed":
      switch fields["reason"] {
      case "port-in-use":
        guard let port = fields["port"].flatMap(Int.init) else { return nil }
        return .failed(reason: .portInUse(port: port), detail: "")
      case "server-error":
        return .failed(reason: .serverError, detail: Self.detail(of: payload))
      default:
        return nil
      }
    default:
      return nil
    }
  }

  /// `key=value` tokens up to (not including) any `detail=` field.
  private static func fields(of payload: String) -> [String: String] {
    var fields: [String: String] = [:]
    for token in payload.split(separator: " ") {
      guard let equals = token.firstIndex(of: "=") else { continue }
      let key = String(token[..<equals])
      if key == "detail" { break }
      fields[key] = String(token[token.index(after: equals)...])
    }
    return fields
  }

  /// Everything after `detail=` — the one field allowed to contain spaces,
  /// so it must be last on the line.
  private static func detail(of payload: String) -> String {
    guard let range = payload.range(of: "detail=") else { return "" }
    return String(payload[range.upperBound...])
  }
}
