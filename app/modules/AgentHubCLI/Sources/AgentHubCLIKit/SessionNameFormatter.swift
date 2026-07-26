import Foundation

public enum SessionNameFormatter {
  public static let maximumLength = 48

  public static func format(_ value: String) -> String? {
    let words = value
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)

    guard !words.isEmpty else { return nil }

    var formatted = ""
    for word in words {
      let candidate = formatted.isEmpty ? word : "\(formatted)-\(word)"
      if candidate.count <= maximumLength {
        formatted = candidate
      } else if formatted.isEmpty {
        formatted = String(word.prefix(maximumLength))
      } else {
        break
      }
    }

    return formatted.isEmpty ? nil : formatted
  }
}
