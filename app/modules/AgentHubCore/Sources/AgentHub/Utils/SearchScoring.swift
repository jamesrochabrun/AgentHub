//
//  SearchScoring.swift
//  AgentHub
//
//  Shared token-based search scoring utility with semantic fallback.
//

import Foundation
import NaturalLanguage

// MARK: - SearchScoring

/// Stateless utility for scoring how well a query matches a text string.
///
/// Scoring tiers:
/// - **100+**: Exact phrase match (contiguous substring)
/// - **70+**: All query tokens present as full words
/// - **40+**: All query tokens match as word prefixes
/// - **10+**: Any single token matches
/// - **1–30**: Semantic similarity via on-device sentence embeddings
///
/// Tiers 1–4 receive a position bonus (0–20) rewarding earlier matches.
/// Tier 5 (semantic) is a fallback when no tokens match.
enum SearchScoring {

  struct MatchResult: Sendable {
    let score: Int
    let position: Int
  }

  /// Scores how well `query` matches `text`.
  /// Returns `nil` when there is no match at all.
  static func score(query: String, against text: String) -> MatchResult? {
    let normalizedQuery = normalize(query)
    let normalizedText = normalize(text)

    guard !normalizedQuery.isEmpty, !normalizedText.isEmpty else {
      return nil
    }

    // Tier 1 – exact phrase (contiguous substring)
    if let range = normalizedText.range(of: normalizedQuery) {
      let pos = normalizedText.distance(from: normalizedText.startIndex, to: range.lowerBound)
      return MatchResult(score: 100 + positionBonus(pos, in: normalizedText), position: pos)
    }

    let queryTokens = tokenize(normalizedQuery)
    guard !queryTokens.isEmpty else { return nil }

    let textTokens = tokenize(normalizedText)
    guard !textTokens.isEmpty else { return nil }

    // Tier 2 – all tokens present as full words
    if let pos = allTokensMatch(queryTokens: queryTokens, textTokens: textTokens, prefixOnly: false) {
      return MatchResult(score: 70 + positionBonus(pos, in: normalizedText), position: pos)
    }

    // Tier 3 – all tokens match as word prefixes
    if let pos = allTokensMatch(queryTokens: queryTokens, textTokens: textTokens, prefixOnly: true) {
      return MatchResult(score: 40 + positionBonus(pos, in: normalizedText), position: pos)
    }

    // Tier 4 – any single token matches
    if let pos = anyTokenMatches(queryTokens: queryTokens, textTokens: textTokens) {
      return MatchResult(score: 10 + positionBonus(pos, in: normalizedText), position: pos)
    }

    // Tier 5 – semantic similarity (fallback when no tokens match)
    if let result = semanticSimilarity(query: normalizedQuery, text: normalizedText) {
      return result
    }

    return nil
  }

  // MARK: - Private Helpers

  private static func normalize(_ input: String) -> String {
    input
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private static let tokenRegex: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: #"[a-z0-9]+"#)
  }()

  private static func tokenize(_ input: String) -> [(value: String, position: Int)] {
    let nsInput = input as NSString
    let matches = tokenRegex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))

    return matches.compactMap { match -> (value: String, position: Int)? in
      guard match.range.location != NSNotFound, match.range.length > 0 else { return nil }
      return (value: nsInput.substring(with: match.range), position: match.range.location)
    }
  }

  private static func positionBonus(_ position: Int, in text: String) -> Int {
    let length = max(text.count, 1)
    let ratio = 1.0 - (Double(min(position, length)) / Double(length))
    return Int(ratio * 20)
  }

  /// Returns the position of the first matching token, or nil if not all query tokens match.
  private static func allTokensMatch(
    queryTokens: [(value: String, position: Int)],
    textTokens: [(value: String, position: Int)],
    prefixOnly: Bool
  ) -> Int? {
    var firstPosition: Int?

    for qt in queryTokens {
      let matched = textTokens.first { tt in
        prefixOnly ? tt.value.hasPrefix(qt.value) : tt.value == qt.value
      }
      guard let matched else { return nil }
      if firstPosition == nil || matched.position < firstPosition! {
        firstPosition = matched.position
      }
    }

    return firstPosition
  }

  /// Returns the position of the first matching token when at least one query token matches.
  private static func anyTokenMatches(
    queryTokens: [(value: String, position: Int)],
    textTokens: [(value: String, position: Int)]
  ) -> Int? {
    var bestPosition: Int?

    for qt in queryTokens {
      if let matched = textTokens.first(where: { $0.value.hasPrefix(qt.value) }) {
        if bestPosition == nil || matched.position < bestPosition! {
          bestPosition = matched.position
        }
      }
    }

    return bestPosition
  }

  // MARK: - Semantic Similarity (Tier 5)

  /// Cosine distance threshold — ignore matches above this (too unrelated).
  private static let semanticDistanceThreshold: Double = 1.0

  /// Maximum score for semantic matches (kept below Tier 4 minimum of 10).
  private static let semanticMaxScore: Int = 30

  /// Lazily loaded on-device sentence embedding model.
  private static let sentenceEmbedding: NLEmbedding? = {
    NLEmbedding.sentenceEmbedding(for: .english)
  }()

  /// Serializes access to `NLEmbedding` which is not thread-safe.
  private static let embeddingLock = NSLock()

  /// Computes semantic similarity between `query` and `text` using on-device
  /// sentence embeddings. Returns nil if the model is unavailable or the
  /// strings are too dissimilar.
  private static func semanticSimilarity(query: String, text: String) -> MatchResult? {
    guard let embedding = sentenceEmbedding else { return nil }

    embeddingLock.lock()
    let distance = embedding.distance(between: query, and: text)
    embeddingLock.unlock()

    // distance is cosine distance: 0.0 = identical, 2.0 = opposite
    // greatestFiniteMagnitude is returned when a string can't be embedded
    guard distance < semanticDistanceThreshold else { return nil }

    let score = max(1, Int((1.0 - distance / semanticDistanceThreshold) * Double(semanticMaxScore)))
    return MatchResult(score: score, position: 0)
  }
}
