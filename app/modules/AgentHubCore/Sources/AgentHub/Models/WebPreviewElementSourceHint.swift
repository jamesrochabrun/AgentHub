//
//  WebPreviewElementSourceHint.swift
//  AgentHub
//
//  Best-effort source locations that framework dev builds already expose
//  (Svelte __svelte_meta, Vue inspector attrs, React fibers, generic
//  data-source attributes). Zero-touch: read-only, never used for direct
//  writes — they anchor agent prompts and the inspector rail.
//

import Foundation

struct WebPreviewElementSourceHint: Equatable, Sendable {
  enum Kind: String, Sendable {
    case svelteMeta
    case vueInspector
    case reactDebugSource
    case reactOwnerChain
    case genericAttribute
  }

  let kind: Kind
  let file: String?
  let line: Int?
  let column: Int?
  let detail: String?

  var frameworkLabel: String {
    switch kind {
    case .svelteMeta: "svelte"
    case .vueInspector: "vue"
    case .reactDebugSource, .reactOwnerChain: "react"
    case .genericAttribute: "source attribute"
    }
  }

  /// One-line rendering for agent prompts and the rail.
  var promptLine: String {
    if let file {
      var location = file
      if let line {
        location += ":\(line)"
        if let column {
          location += ":\(column)"
        }
      }
      return "\(location) (\(frameworkLabel))"
    }
    if let detail {
      return "\(detail) (\(frameworkLabel))"
    }
    return frameworkLabel
  }

  /// Parses the payload returned by the source-hint script.
  static func parse(_ body: Any?) -> [WebPreviewElementSourceHint] {
    guard let dictionary = body as? [String: Any],
          dictionary["ok"] as? Bool == true,
          let rawHints = dictionary["hints"] as? [[String: Any]] else {
      return []
    }

    return rawHints.compactMap { raw in
      guard let kind = (raw["kind"] as? String).flatMap(Kind.init(rawValue:)) else {
        return nil
      }
      return WebPreviewElementSourceHint(
        kind: kind,
        file: nonEmpty(raw["file"] as? String),
        line: positiveInt(raw["line"]),
        column: positiveInt(raw["column"]),
        detail: nonEmpty(raw["detail"] as? String)
      )
    }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func positiveInt(_ value: Any?) -> Int? {
    let intValue: Int?
    if let value = value as? Int {
      intValue = value
    } else if let value = value as? Double {
      intValue = Int(value)
    } else if let value = value as? NSNumber {
      intValue = value.intValue
    } else {
      intValue = nil
    }
    guard let intValue, intValue > 0 else { return nil }
    return intValue
  }
}
