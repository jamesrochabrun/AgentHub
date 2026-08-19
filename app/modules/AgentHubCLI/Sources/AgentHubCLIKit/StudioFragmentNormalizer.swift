import Foundation

/// Reduces whatever HTML an agent sent for a canvas variant to a body fragment
/// plus the CSS it carried.
///
/// Variants share one document, so a variant is a *fragment*, whatever it claims
/// to be: document wrappers are stripped, `<style>` is hoisted so it can be
/// scoped, and `<script>` is removed because JS cannot be scoped the way CSS can
/// (a variant's `document.querySelector('.btn')` would find its neighbour's
/// button). External stylesheets are dropped and reported — remote CSS cannot be
/// scoped either, and silently keeping it would let one variant restyle the
/// canvas.
public enum StudioFragmentNormalizer {
  public struct Output: Equatable, Sendable {
    public let html: String
    public let css: String
    public let warnings: [String]

    public init(html: String, css: String, warnings: [String]) {
      self.html = html
      self.css = css
      self.warnings = warnings
    }
  }

  public static func normalize(_ raw: String) -> Output {
    var html = raw
    var warnings: [String] = []
    var css: [String] = []

    // Comments first, so a commented-out <script> is not "stripped" from inside
    // a comment and reported as if it had been live.
    html = removing(pattern: "<!--.*?-->", from: html)

    // Hoist stylesheets before stripping <head>, which is where most of them live.
    html = replacing(pattern: "<style\\b[^>]*>(.*?)</style\\s*>", in: html) { groups in
      if let body = groups.first { css.append(body) }
      return ""
    }

    let externalStylesheets = matches(
      pattern: "<link\\b[^>]*rel\\s*=\\s*[\"']?stylesheet[\"']?[^>]*>",
      in: html
    )
    if !externalStylesheets.isEmpty {
      warnings.append(
        "Dropped \(externalStylesheets.count) external stylesheet link(s): remote CSS cannot be scoped to one variant. Inline the rules you need."
      )
      html = removing(pattern: "<link\\b[^>]*rel\\s*=\\s*[\"']?stylesheet[\"']?[^>]*>", from: html)
    }

    let scripts = matches(pattern: "<script\\b[^>]*>.*?</script\\s*>", in: html)
    if !scripts.isEmpty {
      warnings.append(
        "Dropped \(scripts.count) <script> block(s): variants share one document, so scripts cannot be scoped. Use agenthub_artifact for interactive HTML."
      )
      html = removing(pattern: "<script\\b[^>]*>.*?</script\\s*>", from: html)
    }

    // Document wrappers. <head> goes entirely (its stylesheets were hoisted above);
    // <html>/<body>/<!DOCTYPE> tags are unwrapped, their content kept.
    html = removing(pattern: "<!DOCTYPE\\b[^>]*>", from: html)
    html = removing(pattern: "<head\\b[^>]*>.*?</head\\s*>", from: html)
    html = removing(pattern: "</?html\\b[^>]*>", from: html)
    html = removing(pattern: "</?body\\b[^>]*>", from: html)

    return Output(
      html: html.trimmingCharacters(in: .whitespacesAndNewlines),
      css: css.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n"),
      warnings: warnings
    )
  }

  // MARK: - Regex helpers

  private static let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

  private static func removing(pattern: String, from text: String) -> String {
    replacing(pattern: pattern, in: text) { _ in "" }
  }

  private static func matches(pattern: String, in text: String) -> [NSTextCheckingResult] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
  }

  private static func replacing(
    pattern: String,
    in text: String,
    with replacement: ([String]) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
    let nsText = text as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
      result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      var groups: [String] = []
      if match.numberOfRanges > 1 {
        for index in 1..<match.numberOfRanges {
          let range = match.range(at: index)
          groups.append(range.location == NSNotFound ? "" : nsText.substring(with: range))
        }
      }
      result += replacement(groups)
      cursor = match.range.location + match.range.length
    }
    result += nsText.substring(from: cursor)
    return result
  }
}
