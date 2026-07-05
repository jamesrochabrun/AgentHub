//
//  WebPreviewStyleProvenance.swift
//  AgentHub
//
//  Per-property winning-declaration provenance computed in-page from CSSOM.
//  A property is only eligible for a Tier-1 direct write when its winner has
//  a rule locator and no uncertainty flags; everything else stays agent-applied.
//

import Foundation

/// Locates one CSS rule inside a runtime stylesheet so it can be matched
/// against a file on disk.
struct WebPreviewCSSRuleLocator: Hashable, Sendable {
  let stylesheetHref: String?
  let styleSheetIndex: Int
  let ruleIndexPath: [Int]
  let selectorText: String
  let specificity: [Int]
  /// Attributes of the owning `<style>`/`<link>` node (captures dev-server
  /// markers like `data-vite-dev-id`).
  let ownerNodeAttributes: [String: String]
}

enum WebPreviewStyleUncertainty: String, Sendable, CaseIterable {
  case layer
  case scope
  case containerQuery
  case unknownGroup
  case adoptedSheet
  case unreadableSheet
  case nestedSelector
  case complexSelector
  case importantConflict
}

struct WebPreviewPropertyWinner: Equatable, Sendable {
  let property: String
  let declaredValue: String
  let isInline: Bool
  let isImportant: Bool
  let rule: WebPreviewCSSRuleLocator?
  let uncertainties: Set<WebPreviewStyleUncertainty>

  /// True when this winner can be considered for a direct file edit.
  var isProvable: Bool {
    !isInline && rule != nil && uncertainties.isEmpty
  }
}

/// A proven Tier-1 write target for one CSS property.
struct WebPreviewDirectStyleTarget: Equatable, Sendable {
  let filePath: String
  /// Rule position inside the CSS document — the file itself, or the inline
  /// `<style>` block addressed by `embeddedStyleBlockIndex`.
  let ruleIndexPath: [Int]
  var contentSHA256: String
  /// When set, `filePath` is an HTML file and the rule lives in its
  /// N-th inline `<style>` block.
  var embeddedStyleBlockIndex: Int?

  init(
    filePath: String,
    ruleIndexPath: [Int],
    contentSHA256: String,
    embeddedStyleBlockIndex: Int? = nil
  ) {
    self.filePath = filePath
    self.ruleIndexPath = ruleIndexPath
    self.contentSHA256 = contentSHA256
    self.embeddedStyleBlockIndex = embeddedStyleBlockIndex
  }
}

/// How an edited style property persists to code.
enum WebPreviewStyleEditTier: Equatable, Sendable {
  case direct(WebPreviewDirectStyleTarget)
  case agent
}

struct WebPreviewStyleProvenance: Equatable, Sendable {
  let winners: [WebPreviewPropertyWinner]
  let unreadableSheetHrefs: [String]
  let hasAdoptedSheets: Bool
  /// Every property name declared by any matched (or possibly-matched) rule,
  /// longhands included — used to keep insertions clear of shorthand
  /// interference.
  let declaredPropertyNames: [String]
  /// Property names declared on the element's `style` attribute.
  let inlinePropertyNames: [String]
  /// The plainest matching rule (no flags, no conditions): where a
  /// brand-new declaration may be inserted.
  let anchorRule: WebPreviewCSSRuleLocator?

  init(
    winners: [WebPreviewPropertyWinner],
    unreadableSheetHrefs: [String],
    hasAdoptedSheets: Bool,
    declaredPropertyNames: [String] = [],
    inlinePropertyNames: [String] = [],
    anchorRule: WebPreviewCSSRuleLocator? = nil
  ) {
    self.winners = winners
    self.unreadableSheetHrefs = unreadableSheetHrefs
    self.hasAdoptedSheets = hasAdoptedSheets
    self.declaredPropertyNames = declaredPropertyNames
    self.inlinePropertyNames = inlinePropertyNames
    self.anchorRule = anchorRule
  }

  func winner(for property: String) -> WebPreviewPropertyWinner? {
    winners.first { $0.property == property }
  }

  /// Parses the dictionary returned by the in-page provenance script.
  static func parse(_ body: Any?) -> WebPreviewStyleProvenance? {
    guard let dictionary = body as? [String: Any],
          dictionary["ok"] as? Bool == true else {
      return nil
    }

    let unreadable = dictionary["unreadableSheets"] as? [String] ?? []
    let hasAdopted = dictionary["hasAdoptedSheets"] as? Bool ?? false
    let rawWinners = dictionary["winners"] as? [[String: Any]] ?? []

    let winners = rawWinners.compactMap { raw -> WebPreviewPropertyWinner? in
      guard let property = raw["property"] as? String,
            let declaredValue = raw["declaredValue"] as? String else {
        return nil
      }

      let flags = (raw["flags"] as? [String] ?? [])
        .compactMap(WebPreviewStyleUncertainty.init(rawValue:))

      return WebPreviewPropertyWinner(
        property: property,
        declaredValue: declaredValue,
        isInline: raw["isInline"] as? Bool ?? false,
        isImportant: raw["isImportant"] as? Bool ?? false,
        rule: parseRuleLocator(raw["rule"]),
        uncertainties: Set(flags)
      )
    }

    return WebPreviewStyleProvenance(
      winners: winners,
      unreadableSheetHrefs: unreadable,
      hasAdoptedSheets: hasAdopted,
      declaredPropertyNames: dictionary["declaredNames"] as? [String] ?? [],
      inlinePropertyNames: dictionary["inlineNames"] as? [String] ?? [],
      anchorRule: parseRuleLocator(dictionary["anchor"])
    )
  }

  private static func parseRuleLocator(_ value: Any?) -> WebPreviewCSSRuleLocator? {
    guard let rawRule = value as? [String: Any],
          let selectorText = rawRule["selectorText"] as? String,
          let ruleIndexPath = intArray(rawRule["ruleIndexPath"]),
          let styleSheetIndex = intValue(rawRule["styleSheetIndex"]) else {
      return nil
    }
    return WebPreviewCSSRuleLocator(
      stylesheetHref: rawRule["stylesheetHref"] as? String,
      styleSheetIndex: styleSheetIndex,
      ruleIndexPath: ruleIndexPath,
      selectorText: selectorText,
      specificity: intArray(rawRule["specificity"]) ?? [],
      ownerNodeAttributes: rawRule["ownerNodeAttributes"] as? [String: String] ?? [:]
    )
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let intValue = value as? Int { return intValue }
    if let doubleValue = value as? Double { return Int(doubleValue) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
  }

  private static func intArray(_ value: Any?) -> [Int]? {
    guard let array = value as? [Any] else { return nil }
    let ints = array.compactMap(intValue)
    return ints.count == array.count ? ints : nil
  }
}
