//
//  WebPreviewStaticStyleResolver.swift
//  AgentHub
//
//  Direct-write target resolution for static (`file://`) previews. CSSOM is
//  unreadable for file-scheme linked stylesheets, but a static preview's
//  sources ARE the files on disk — so rules are enumerated by parsing the
//  served HTML's stylesheets in Swift, the page is asked only for
//  matches/media/supports verdicts, and the winning declaration per property
//  is computed here. Winners in linked CSS files or inline <style> blocks
//  become Tier-1 direct targets; anything uncertain stays agent-applied.
//

import Foundation
import WebKit

// MARK: - Candidate model (internal to the static winner computation)

struct StaticStyleRuleCandidate: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case linkedFile(path: String)
    case inlineBlock(ordinal: Int)
  }

  let source: Source
  let ruleIndexPath: [Int]
  let selectorParts: [String]
  /// Indices into the shared media/supports condition arrays that must all hold.
  let mediaConditionIndices: [Int]
  let supportsConditionIndices: [Int]
  /// True for rules inside @layer/@scope/@container/unknown groups or with
  /// functional pseudo-classes the specificity calculator cannot score.
  let isFlagged: Bool
  let declarations: [StaticStyleDeclaration]
}

struct StaticStyleDeclaration: Equatable, Sendable {
  let name: String
  let value: String
  let isImportant: Bool
}

// MARK: - Protocol

@MainActor
protocol WebPreviewStaticStyleResolving {
  func resolveDirectTargets(
    elementSelector: String,
    servedFilePath: String,
    projectPath: String,
    properties: [String],
    in webView: WKWebView
  ) async -> [String: WebPreviewDirectStyleTarget]
}

// MARK: - Resolver

@MainActor
struct WebPreviewStaticStyleResolver: WebPreviewStaticStyleResolving {
  private let fileService: any ProjectFileServiceProtocol
  private let cssEditor: any CSSSourceEditing
  private let probe: any WebPreviewStaticMatchProbing

  init(
    fileService: any ProjectFileServiceProtocol = ProjectFileService.shared,
    cssEditor: any CSSSourceEditing = CSSSourceEditor(),
    probe: (any WebPreviewStaticMatchProbing)? = nil
  ) {
    self.fileService = fileService
    self.cssEditor = cssEditor
    self.probe = probe ?? WebPreviewStaticMatchProbe()
  }

  func resolveDirectTargets(
    elementSelector: String,
    servedFilePath: String,
    projectPath: String,
    properties: [String],
    in webView: WKWebView
  ) async -> [String: WebPreviewDirectStyleTarget] {
    guard let html = try? await fileService.readFile(at: servedFilePath, projectPath: projectPath) else {
      return [:]
    }

    var candidates: [StaticStyleRuleCandidate] = []
    var mediaConditions: [String] = []
    var supportsConditions: [String] = []
    var fileContents: [String: String] = [servedFilePath: html]

    for source in HTMLStylesheetScanner.stylesheetSources(in: html) {
      switch source {
      case .linked(let href, let media):
        guard let path = Self.resolveLinkedPath(href: href, servedFilePath: servedFilePath, projectPath: projectPath),
              let css = try? await fileService.readFile(at: path, projectPath: projectPath),
              let document = try? cssEditor.parse(css) else {
          // External or unparseable stylesheets are skipped: worst case an
          // edit lands in a rule they override (visible, never corrupting).
          continue
        }
        fileContents[path] = css
        let sheetMedia = media.map { registerCondition($0, in: &mediaConditions) }
        Self.collect(
          rules: document.rules,
          source: .linkedFile(path: path),
          inheritedMedia: sheetMedia.map { [$0] } ?? [],
          inheritedSupports: [],
          inheritedFlagged: false,
          mediaConditions: &mediaConditions,
          supportsConditions: &supportsConditions,
          into: &candidates
        )

      case .inlineBlock(let contentRange, let ordinal, let media):
        let bytes = Array(html.utf8)
        guard contentRange.lowerBound >= 0, contentRange.upperBound <= bytes.count,
              let css = String(bytes: bytes[contentRange], encoding: .utf8),
              let document = try? cssEditor.parse(css) else {
          continue
        }
        let sheetMedia = media.map { registerCondition($0, in: &mediaConditions) }
        Self.collect(
          rules: document.rules,
          source: .inlineBlock(ordinal: ordinal),
          inheritedMedia: sheetMedia.map { [$0] } ?? [],
          inheritedSupports: [],
          inheritedFlagged: false,
          mediaConditions: &mediaConditions,
          supportsConditions: &supportsConditions,
          into: &candidates
        )
      }
    }

    guard !candidates.isEmpty else { return [:] }

    // Deduplicated flat selector list for the single page round-trip.
    var selectorIndex: [String: Int] = [:]
    var flatSelectors: [String] = []
    for candidate in candidates {
      for part in candidate.selectorParts where selectorIndex[part] == nil {
        selectorIndex[part] = flatSelectors.count
        flatSelectors.append(part)
      }
    }

    guard let verdicts = await probe.probe(
      selector: elementSelector,
      candidateSelectors: flatSelectors,
      mediaConditions: mediaConditions,
      supportsConditions: supportsConditions,
      properties: properties,
      in: webView
    ) else {
      return [:]
    }

    var winners = Self.computeWinners(
      candidates: candidates,
      selectorIndex: selectorIndex,
      verdicts: verdicts,
      properties: properties
    )

    // Properties no stylesheet declares at all still deserve an exact write:
    // insert them into the element's best unconditioned matching rule.
    if let anchor = Self.insertionAnchor(
      candidates: candidates,
      selectorIndex: selectorIndex,
      verdicts: verdicts
    ) {
      for property in Self.insertableProperties(
        candidates: candidates,
        selectorIndex: selectorIndex,
        verdicts: verdicts,
        properties: properties
      ) where winners[property] == nil {
        winners[property] = anchor
      }
    }

    var targets: [String: WebPreviewDirectStyleTarget] = [:]
    for (property, winner) in winners {
      switch winner.source {
      case .linkedFile(let path):
        guard let content = fileContents[path] else { continue }
        targets[property] = WebPreviewDirectStyleTarget(
          filePath: path,
          ruleIndexPath: winner.ruleIndexPath,
          contentSHA256: StylesheetSourceMapper.sha256(of: content),
          embeddedStyleBlockIndex: nil
        )
      case .inlineBlock(let ordinal):
        targets[property] = WebPreviewDirectStyleTarget(
          filePath: servedFilePath,
          ruleIndexPath: winner.ruleIndexPath,
          contentSHA256: StylesheetSourceMapper.sha256(of: html),
          embeddedStyleBlockIndex: ordinal
        )
      }
    }
    return targets
  }

  // MARK: - Winner computation (pure)

  nonisolated static func computeWinners(
    candidates: [StaticStyleRuleCandidate],
    selectorIndex: [String: Int],
    verdicts: WebPreviewStaticMatchVerdicts,
    properties: [String]
  ) -> [String: StaticStyleRuleCandidate] {
    struct Scored {
      let candidate: StaticStyleRuleCandidate
      let specificity: [Int]
      let order: Int
      let isImportant: Bool
      let isFlagged: Bool
    }

    var winners: [String: StaticStyleRuleCandidate] = [:]

    for property in properties {
      let propertyName = property.lowercased()
      var best: Scored?

      for (order, candidate) in candidates.enumerated() {
        let conditionsHold =
          candidate.mediaConditionIndices.allSatisfy { index in
            index < verdicts.mediaMatches.count && verdicts.mediaMatches[index]
          }
          && candidate.supportsConditionIndices.allSatisfy { index in
            index < verdicts.supportsMatches.count && verdicts.supportsMatches[index]
          }
        guard conditionsHold else { continue }

        var bestSpecificity: [Int]?
        var partIsComplex = false
        for part in candidate.selectorParts {
          guard let flatIndex = selectorIndex[part],
                flatIndex < verdicts.selectorMatches.count,
                verdicts.selectorMatches[flatIndex] else {
            continue
          }
          if CSSSelectorSpecificity.hasComplexPseudo(part) {
            partIsComplex = true
          }
          let specificity = CSSSelectorSpecificity.compute(part)
          if bestSpecificity == nil || CSSSelectorSpecificity.compare(specificity, bestSpecificity!) > 0 {
            bestSpecificity = specificity
          }
        }
        guard let specificity = bestSpecificity else { continue }

        guard let declaration = candidate.declarations.last(where: { $0.name == propertyName }) else {
          continue
        }

        let scored = Scored(
          candidate: candidate,
          specificity: specificity,
          order: order,
          isImportant: declaration.isImportant,
          isFlagged: candidate.isFlagged || partIsComplex
        )

        if let current = best {
          if scored.isImportant != current.isImportant {
            if scored.isImportant { best = scored }
          } else {
            let comparison = CSSSelectorSpecificity.compare(scored.specificity, current.specificity)
            if comparison > 0 || (comparison == 0 && scored.order >= current.order) {
              best = scored
            }
          }
        } else {
          best = scored
        }
      }

      guard let winner = best else { continue }
      // The element's style attribute beats non-important rule declarations,
      // and flagged winners cannot be ordered confidently — both stay agent.
      if verdicts.inlineStyles[propertyName] != nil, !winner.isImportant { continue }
      if winner.isFlagged { continue }

      winners[property] = winner.candidate
    }

    return winners
  }

  /// The rule a brand-new declaration should be inserted into: the matching,
  /// unflagged, unconditioned (no media/supports) candidate with the highest
  /// specificity, breaking ties by source order. Conditioned rules are
  /// excluded because an inserted declaration must apply in every
  /// environment, exactly like the live edit the user previewed.
  nonisolated static func insertionAnchor(
    candidates: [StaticStyleRuleCandidate],
    selectorIndex: [String: Int],
    verdicts: WebPreviewStaticMatchVerdicts
  ) -> StaticStyleRuleCandidate? {
    var best: (candidate: StaticStyleRuleCandidate, specificity: [Int], order: Int)?

    for (order, candidate) in candidates.enumerated() {
      guard !candidate.isFlagged,
            candidate.mediaConditionIndices.isEmpty,
            candidate.supportsConditionIndices.isEmpty else {
        continue
      }

      var bestSpecificity: [Int]?
      var hasComplexPart = false
      for part in candidate.selectorParts {
        guard let flatIndex = selectorIndex[part],
              flatIndex < verdicts.selectorMatches.count,
              verdicts.selectorMatches[flatIndex] else {
          continue
        }
        if CSSSelectorSpecificity.hasComplexPseudo(part) {
          hasComplexPart = true
          break
        }
        let specificity = CSSSelectorSpecificity.compute(part)
        if bestSpecificity == nil || CSSSelectorSpecificity.compare(specificity, bestSpecificity!) > 0 {
          bestSpecificity = specificity
        }
      }
      guard !hasComplexPart, let specificity = bestSpecificity else { continue }

      if let current = best {
        let comparison = CSSSelectorSpecificity.compare(specificity, current.specificity)
        if comparison > 0 || (comparison == 0 && order >= current.order) {
          best = (candidate, specificity, order)
        }
      } else {
        best = (candidate, specificity, order)
      }
    }

    return best?.candidate
  }

  /// Properties that are safe to insert: no rule that matches the element
  /// (or whose match is uncertain — flagged/nested) declares them or a
  /// related shorthand/longhand, and the element's style attribute doesn't
  /// either. Conditioned rules count even when their condition doesn't
  /// currently hold, so a resize can't reorder the persisted cascade.
  nonisolated static func insertableProperties(
    candidates: [StaticStyleRuleCandidate],
    selectorIndex: [String: Int],
    verdicts: WebPreviewStaticMatchVerdicts,
    properties: [String]
  ) -> [String] {
    var declared = Set(verdicts.inlineDeclaredNames.map { $0.lowercased() })
    declared.formUnion(verdicts.inlineStyles.keys.map { $0.lowercased() })

    for candidate in candidates {
      let matchIsRelevant = candidate.isFlagged || candidate.selectorParts.contains { part in
        guard let flatIndex = selectorIndex[part],
              flatIndex < verdicts.selectorMatches.count else {
          return false
        }
        return verdicts.selectorMatches[flatIndex]
      }
      guard matchIsRelevant else { continue }
      for declaration in candidate.declarations {
        declared.insert(declaration.name.lowercased())
      }
    }

    return properties.filter { !CSSPropertyFamily.conflicts($0, with: declared) }
  }

  // MARK: - Rule collection

  nonisolated private static func collect(
    rules: [CSSSourceRule],
    source: StaticStyleRuleCandidate.Source,
    inheritedMedia: [Int],
    inheritedSupports: [Int],
    inheritedFlagged: Bool,
    mediaConditions: inout [String],
    supportsConditions: inout [String],
    into candidates: inout [StaticStyleRuleCandidate]
  ) {
    for rule in rules {
      if rule.isAtRule {
        let prelude = rule.prelude.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = prelude.lowercased()
        var media = inheritedMedia
        var supports = inheritedSupports
        var flagged = inheritedFlagged

        if lowercased.hasPrefix("@media") {
          let condition = String(prelude.dropFirst("@media".count)).trimmingCharacters(in: .whitespacesAndNewlines)
          media.append(registerConditionStatic(condition, in: &mediaConditions))
        } else if lowercased.hasPrefix("@supports") {
          let condition = String(prelude.dropFirst("@supports".count)).trimmingCharacters(in: .whitespacesAndNewlines)
          supports.append(registerConditionStatic(condition, in: &supportsConditions))
        } else {
          // @layer/@scope/@container/@keyframes/anything else: cascade order
          // cannot be modeled confidently — flag descendants.
          flagged = true
        }

        collect(
          rules: rule.children,
          source: source,
          inheritedMedia: media,
          inheritedSupports: supports,
          inheritedFlagged: flagged,
          mediaConditions: &mediaConditions,
          supportsConditions: &supportsConditions,
          into: &candidates
        )
        continue
      }

      let prelude = rule.prelude
      let isNested = prelude.contains("&")
      candidates.append(StaticStyleRuleCandidate(
        source: source,
        ruleIndexPath: rule.indexPath,
        selectorParts: CSSSelectorSpecificity.selectorParts(prelude),
        mediaConditionIndices: inheritedMedia,
        supportsConditionIndices: inheritedSupports,
        isFlagged: inheritedFlagged || isNested,
        declarations: rule.declarations.map {
          StaticStyleDeclaration(name: $0.name, value: $0.valueText, isImportant: $0.isImportant)
        }
      ))

      // Nested child style rules cannot be matched without composing `&`
      // selectors; collect them flagged so their properties stay agent-tier.
      collect(
        rules: rule.children,
        source: source,
        inheritedMedia: inheritedMedia,
        inheritedSupports: inheritedSupports,
        inheritedFlagged: true,
        mediaConditions: &mediaConditions,
        supportsConditions: &supportsConditions,
        into: &candidates
      )
    }
  }

  // MARK: - Helpers

  private func registerCondition(_ condition: String, in conditions: inout [String]) -> Int {
    Self.registerConditionStatic(condition, in: &conditions)
  }

  nonisolated private static func registerConditionStatic(_ condition: String, in conditions: inout [String]) -> Int {
    if let existing = conditions.firstIndex(of: condition) {
      return existing
    }
    conditions.append(condition)
    return conditions.count - 1
  }

  nonisolated static func resolveLinkedPath(href: String, servedFilePath: String, projectPath: String) -> String? {
    guard !href.isEmpty else { return nil }
    let lowered = href.lowercased()
    guard !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://"), !lowered.hasPrefix("//"),
          !lowered.hasPrefix("data:") else {
      return nil
    }

    let withoutQuery = href.split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
    let baseURL = URL(fileURLWithPath: servedFilePath).deletingLastPathComponent()
    let resolved: String
    if withoutQuery.hasPrefix("file://"), let url = URL(string: withoutQuery) {
      resolved = url.path
    } else if withoutQuery.hasPrefix("/") {
      resolved = projectPath + withoutQuery
    } else {
      resolved = baseURL.appendingPathComponent(withoutQuery).path
    }

    let normalized = URL(fileURLWithPath: resolved).standardizedFileURL.resolvingSymlinksInPath().path
    let normalizedProject = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path
    guard normalized == normalizedProject || normalized.hasPrefix(normalizedProject + "/") else {
      return nil
    }
    return normalized
  }
}
