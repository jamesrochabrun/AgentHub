import AgentHubCLIKit
import Foundation

/// Composes the prompt for **Promote…** — the one action in Studio that asks
/// the agent to write real code.
///
/// Sends the variant's *original* markup and CSS, never the scoped rewrite:
/// `.studio-artboard[data-variant=…]` selectors are an artefact of the canvas
/// and must never reach a codebase.
public enum StudioPromotionPromptBuilder {
  public static func prompt(artifact: StudioArtifact, variantName: String) -> String? {
    guard artifact.kind == .canvas,
          let variant = artifact.variants.first(where: { $0.name == variantName })
    else {
      return nil
    }

    var lines: [String] = []
    var opening = "Implement the \"\(variant.name)\" variant from the Studio design canvas \"\(artifact.title)\" (id \(artifact.id)) in the real project"
    if let sourcePath = artifact.sourcePath, !sourcePath.isEmpty {
      opening += ", in \(sourcePath)"
    }
    opening += "."
    lines.append(opening)
    lines.append("")

    lines.append("Variant markup:")
    lines.append("```html")
    lines.append(variant.html)
    lines.append("```")
    if !variant.css.isEmpty {
      lines.append("")
      lines.append("Variant CSS:")
      lines.append("```css")
      lines.append(variant.css)
      lines.append("```")
    }
    if let notes = variant.notes, !notes.isEmpty {
      lines.append("")
      lines.append("Design notes: \(notes)")
    }
    lines.append("")
    lines.append("Preserve the component's existing behaviour, props, and public API; change presentation only, and follow the project's conventions rather than pasting this markup verbatim. When done, list the files you changed.")

    return lines.joined(separator: "\n")
  }
}
