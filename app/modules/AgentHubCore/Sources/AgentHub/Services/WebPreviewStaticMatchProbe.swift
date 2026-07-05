//
//  WebPreviewStaticMatchProbe.swift
//  AgentHub
//
//  One-round-trip page probe for the static-preview style resolver: which of
//  the file-derived selectors match the element, which media/supports
//  conditions currently hold, and what the element's style attribute declares.
//  Everything else (rule enumeration, cascade winner) is computed in Swift
//  from the files on disk.
//

import Foundation
import WebKit

struct WebPreviewStaticMatchVerdicts: Equatable, Sendable {
  let selectorMatches: [Bool]
  let mediaMatches: [Bool]
  let supportsMatches: [Bool]
  /// Property → declared value on the element's `style` attribute.
  let inlineStyles: [String: String]
  /// Every property name the element's `style` attribute declares (longhands
  /// included), so insertions can detect shorthand interference.
  let inlineDeclaredNames: [String]

  init(
    selectorMatches: [Bool],
    mediaMatches: [Bool],
    supportsMatches: [Bool],
    inlineStyles: [String: String],
    inlineDeclaredNames: [String] = []
  ) {
    self.selectorMatches = selectorMatches
    self.mediaMatches = mediaMatches
    self.supportsMatches = supportsMatches
    self.inlineStyles = inlineStyles
    self.inlineDeclaredNames = inlineDeclaredNames
  }

  static func parse(_ body: Any?) -> WebPreviewStaticMatchVerdicts? {
    guard let dictionary = body as? [String: Any],
          dictionary["ok"] as? Bool == true,
          let selectorMatches = boolArray(dictionary["matches"]),
          let mediaMatches = boolArray(dictionary["media"]),
          let supportsMatches = boolArray(dictionary["supports"]) else {
      return nil
    }
    return WebPreviewStaticMatchVerdicts(
      selectorMatches: selectorMatches,
      mediaMatches: mediaMatches,
      supportsMatches: supportsMatches,
      inlineStyles: dictionary["inline"] as? [String: String] ?? [:],
      inlineDeclaredNames: dictionary["inlineNames"] as? [String] ?? []
    )
  }

  private static func boolArray(_ value: Any?) -> [Bool]? {
    guard let array = value as? [Any] else { return nil }
    let bools = array.map { ($0 as? Bool) ?? (($0 as? NSNumber)?.boolValue ?? false) }
    return bools
  }
}

@MainActor
protocol WebPreviewStaticMatchProbing {
  func probe(
    selector: String,
    candidateSelectors: [String],
    mediaConditions: [String],
    supportsConditions: [String],
    properties: [String],
    in webView: WKWebView
  ) async -> WebPreviewStaticMatchVerdicts?
}

@MainActor
struct WebPreviewStaticMatchProbe: WebPreviewStaticMatchProbing {
  func probe(
    selector: String,
    candidateSelectors: [String],
    mediaConditions: [String],
    supportsConditions: [String],
    properties: [String],
    in webView: WKWebView
  ) async -> WebPreviewStaticMatchVerdicts? {
    guard let script = Self.script(
      selector: selector,
      candidateSelectors: candidateSelectors,
      mediaConditions: mediaConditions,
      supportsConditions: supportsConditions,
      properties: properties
    ) else {
      return nil
    }

    let result: Any? = await withCheckedContinuation { continuation in
      webView.evaluateJavaScript(script) { value, error in
        continuation.resume(returning: error == nil ? value : nil)
      }
    }

    return WebPreviewStaticMatchVerdicts.parse(result)
  }

  static func script(
    selector: String,
    candidateSelectors: [String],
    mediaConditions: [String],
    supportsConditions: [String],
    properties: [String]
  ) -> String? {
    guard let selectorJSON = jsonLiteral(selector),
          let candidatesJSON = jsonLiteral(candidateSelectors),
          let mediaJSON = jsonLiteral(mediaConditions),
          let supportsJSON = jsonLiteral(supportsConditions),
          let propertiesJSON = jsonLiteral(properties) else {
      return nil
    }

    return """
    (function() {
      var SELECTOR = \(selectorJSON);
      var CANDIDATES = \(candidatesJSON);
      var MEDIA = \(mediaJSON);
      var SUPPORTS = \(supportsJSON);
      var PROPERTIES = \(propertiesJSON);

      var el = null;
      try { el = document.querySelector(SELECTOR); } catch (err) {}
      if (!el) { return { ok: false, reason: 'element-not-found' }; }

      var matches = CANDIDATES.map(function(candidate) {
        try { return el.matches(candidate); } catch (err) { return false; }
      });
      var media = MEDIA.map(function(condition) {
        try { return window.matchMedia(condition).matches; } catch (err) { return false; }
      });
      var supports = SUPPORTS.map(function(condition) {
        try { return CSS.supports(condition); } catch (err) { return false; }
      });

      var inline = {};
      PROPERTIES.forEach(function(property) {
        try {
          var value = el.style.getPropertyValue(property);
          if (value) { inline[property] = value; }
        } catch (err) {}
      });

      var inlineNames = [];
      try {
        for (var n = 0; n < el.style.length; n++) { inlineNames.push(el.style[n]); }
      } catch (err) {}

      return { ok: true, matches: matches, media: media, supports: supports, inline: inline, inlineNames: inlineNames };
    })();
    """
  }

  private static func jsonLiteral(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let wrapped = String(data: data, encoding: .utf8),
          wrapped.hasPrefix("["), wrapped.hasSuffix("]") else {
      return nil
    }
    return String(wrapped.dropFirst().dropLast())
  }
}
