//
//  WebPreviewDesignEditPromptComposer.swift
//  AgentHub
//
//  Composes the agent instruction for a batch of pending design edits.
//  The instruction is wrapped by `ElementInspectorPromptBuilder.buildPrompt`
//  at send time, which contributes the element identity and computed styles.
//

import Foundation

enum WebPreviewDesignEditPromptComposer {
  /// Builds the minimal-delta instruction describing the batched edits.
  /// Returns nil when the batch contains no changes.
  static func instruction(
    for batch: WebPreviewPendingDesignEditBatch,
    previewContext: String? = nil,
    candidateFiles: [String] = [],
    sourceHints: [String] = [],
    declaredSources: [String: String] = [:],
    provenFiles: [String: String] = [:]
  ) -> String? {
    guard !batch.isEmpty else { return nil }

    var lines = ["Apply these design changes to this element:"]

    for change in batch.styleChanges {
      if let oldValue = change.oldValue {
        lines.append("- \(change.property): \(oldValue) → \(change.newValue)")
      } else {
        lines.append("- \(change.property): \(change.newValue)")
      }
    }

    if let textChange = batch.textChange {
      if let oldText = textChange.oldText, !oldText.isEmpty {
        lines.append("- text content: \"\(oldText)\" → \"\(textChange.newText)\"")
      } else {
        lines.append("- text content: \"\(textChange.newText)\"")
      }
    }

    let declarationSites = batch.styleChanges.compactMap { change -> String? in
      let declared = declaredSources[change.property]
      let provenFile = provenFiles[change.property]
      switch (declared, provenFile) {
      case (let declared?, let provenFile?):
        return "- \(change.property): \(declared) — verified in \(provenFile)"
      case (let declared?, nil):
        return "- \(change.property): \(declared)"
      case (nil, let provenFile?):
        return "- \(change.property): declared in \(provenFile)"
      case (nil, nil):
        return nil
      }
    }
    if !declarationSites.isEmpty {
      lines.append("")
      lines.append(
        "Where these values live today (AgentHub matched the winning rule — "
          + "change the declaration in place, do not paste the computed value elsewhere):"
      )
      lines.append(contentsOf: declarationSites)
    }

    if let previewContext, !previewContext.isEmpty {
      lines.append("")
      lines.append("Preview context: \(previewContext)")
    }

    if !sourceHints.isEmpty {
      lines.append("")
      lines.append("Framework source metadata:")
      lines.append(contentsOf: sourceHints.map { "- \($0)" })
    }

    if !candidateFiles.isEmpty {
      lines.append("")
      lines.append("Possible source files (unverified hints — confirm before editing):")
      lines.append(contentsOf: candidateFiles.map { "- \($0)" })
    }

    lines.append("")
    lines.append(
      "Apply exactly these changes using the project's existing styling approach "
        + "(Tailwind classes, CSS modules, styled-components, or plain CSS — match what the code already uses). "
        + "Change only what is needed to reach these values; do not reformat or restructure unrelated code."
    )

    return lines.joined(separator: "\n")
  }

  /// Builds the compact one-line delta shown on the queued "Edits" chip.
  /// Returns nil when the batch contains no changes.
  static func summary(for batch: WebPreviewPendingDesignEditBatch) -> String? {
    guard !batch.isEmpty else { return nil }

    var parts = batch.styleChanges.map { change -> String in
      if let oldValue = change.oldValue {
        return "\(change.property) \(oldValue) → \(change.newValue)"
      }
      return "\(change.property) \(change.newValue)"
    }

    if let textChange = batch.textChange {
      parts.append("text \u{201C}\(condensed(textChange.newText))\u{201D}")
    }

    return parts.joined(separator: " · ")
  }

  /// Collapses whitespace and clips long text so a chip stays one line.
  private static func condensed(_ text: String, limit: Int = 60) -> String {
    let collapsed = text
      .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
    guard collapsed.count > limit else { return collapsed }
    return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
  }
}
