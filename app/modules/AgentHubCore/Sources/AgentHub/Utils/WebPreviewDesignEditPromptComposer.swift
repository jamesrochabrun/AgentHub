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
    sourceHints: [String] = []
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
}
