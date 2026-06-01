import Foundation

/// Researches the capabilities and strengths of a provider's latest model.
public protocol ModelCapabilityResearching: Sendable {
  func researchCapabilities(for provider: WorktreeLaunchProvider) async -> ModelCapabilityProfile
}

/// Abstraction over the single HTTP request performed per provider, so the research
/// service can be unit-tested with canned responses (or a deliberately failing fetcher)
/// instead of hitting the network.
public protocol WebPageFetching: Sendable {
  func fetchText(from url: URL) async throws -> String
}

/// Default `URLSession`-backed fetcher.
public struct URLSessionWebPageFetcher: WebPageFetching {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func fetchText(from url: URL) async throws -> String {
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    // A desktop user-agent keeps the lightweight HTML search endpoint from returning
    // an empty/blocked body.
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
      forHTTPHeaderField: "User-Agent"
    )
    let (data, _) = try await session.data(for: request)
    return String(decoding: data, as: UTF8.self)
  }
}

/// Returns curated local model profiles by default. Optional web lookup is available
/// only when explicitly enabled by the caller.
public struct WebModelCapabilityResearchService: ModelCapabilityResearching {
  private let fetcher: WebPageFetching
  private let allowsNetworkLookup: Bool

  public init(
    fetcher: WebPageFetching = URLSessionWebPageFetcher(),
    allowsNetworkLookup: Bool = false
  ) {
    self.fetcher = fetcher
    self.allowsNetworkLookup = allowsNetworkLookup
  }

  public func researchCapabilities(for provider: WorktreeLaunchProvider) async -> ModelCapabilityProfile {
    let baseline = Self.curatedProfile(for: provider)
    guard allowsNetworkLookup else { return baseline }
    guard let url = Self.searchURL(for: provider) else { return baseline }

    do {
      let html = try await fetcher.fetchText(from: url)
      let snippet = Self.extractSnippet(from: html)
      guard !snippet.isEmpty else { return baseline }

      let model = Self.extractModelName(from: snippet, provider: provider) ?? baseline.model
      // Strengths surfaced by the web result, merged with the curated baseline so a thin
      // snippet never erases known strengths. Web-derived tags take precedence in ordering.
      let webStrengths = CapabilityTag.rankedTags(in: snippet)
      let mergedStrengths = Self.mergeStrengths(primary: webStrengths, fallback: baseline.strengths)

      return ModelCapabilityProfile(
        provider: provider,
        model: model,
        strengths: mergedStrengths,
        summary: Self.condense(snippet),
        sourceURL: url.absoluteString,
        sourcedFromWeb: true
      )
    } catch {
      return baseline
    }
  }

  // MARK: - Query

  static func searchURL(for provider: WorktreeLaunchProvider) -> URL? {
    let query: String
    switch provider {
    case .claude:
      query = "Anthropic Claude latest model capabilities strengths coding reasoning"
    case .codex:
      query = "OpenAI Codex GPT latest model capabilities strengths coding reasoning"
    }
    var components = URLComponents(string: "https://html.duckduckgo.com/html/")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
    return components?.url
  }

  // MARK: - Parsing

  /// Concatenates the text of the top result snippets from the DuckDuckGo HTML page.
  static func extractSnippet(from html: String) -> String {
    let matches = html.matches(of: #/class="result__snippet"[^>]*>(.*?)</a>/#.dotMatchesNewlines())
    let snippets = matches.prefix(5).map { stripHTML(String($0.1)) }
    let joined = snippets.joined(separator: " ")
    return joined.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func stripHTML(_ value: String) -> String {
    let withoutTags = value.replacingOccurrences(
      of: "<[^>]+>",
      with: " ",
      options: .regularExpression
    )
    let decoded = withoutTags
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&#x27;", with: "'")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&nbsp;", with: " ")
    return decoded
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Pulls a concrete model name (e.g. "Claude Opus 4.8", "GPT-5.5") out of the snippet
  /// so the plan reflects whatever the web reports as current.
  static func extractModelName(from snippet: String, provider: WorktreeLaunchProvider) -> String? {
    switch provider {
    case .claude:
      if let match = snippet.firstMatch(of: #/(Claude\s+(?:Opus|Sonnet|Haiku)\s+\d+(?:\.\d+)?)/#) {
        return String(match.1)
      }
    case .codex:
      if let match = snippet.firstMatch(of: #/(GPT-\d+(?:\.\d+)?)/#) {
        return String(match.1)
      }
    }
    return nil
  }

  static func mergeStrengths(primary: [CapabilityTag], fallback: [CapabilityTag]) -> [CapabilityTag] {
    var ordered: [CapabilityTag] = []
    for tag in primary + fallback where !ordered.contains(tag) {
      ordered.append(tag)
    }
    return Array(ordered.prefix(6))
  }

  static func condense(_ snippet: String) -> String {
    let limit = 320
    guard snippet.count > limit else { return snippet }
    let prefix = snippet.prefix(limit)
    if let lastSpace = prefix.lastIndex(of: " ") {
      return String(prefix[..<lastSpace]) + "…"
    }
    return String(prefix) + "…"
  }

  // MARK: - Curated fallback

  /// Curated, offline knowledge used when the web search is unavailable. Kept deliberately
  /// distinct per provider so matching still produces a sensible split with no network.
  static func curatedProfile(for provider: WorktreeLaunchProvider) -> ModelCapabilityProfile {
    switch provider {
    case .claude:
      return ModelCapabilityProfile(
        provider: .claude,
        model: "Claude Opus 4.8",
        strengths: [.coding, .refactoring, .debugging, .reasoning, .longContext, .testing],
        summary: "Anthropic's Claude Opus excels at agentic, multi-file coding: large refactors, "
          + "debugging across a codebase, careful test writing, and sustained long-context reasoning.",
        sourceURL: nil,
        sourcedFromWeb: false
      )
    case .codex:
      return ModelCapabilityProfile(
        provider: .codex,
        model: "GPT-5.5",
        strengths: [.reasoning, .dataAnalysis, .frontend, .research, .coding, .documentation],
        summary: "OpenAI's latest model is strong at algorithmic reasoning, data analysis, "
          + "frontend scaffolding, broad research, and clear documentation.",
        sourceURL: nil,
        sourcedFromWeb: false
      )
    }
  }
}
