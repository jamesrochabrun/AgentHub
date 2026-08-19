import AgentHubCLIKit
import Canvas
import Foundation

/// Composes the prompt sent when the user comments on an element in a Studio
/// artifact and presses Send.
///
/// Send iterates the surface: the prompt tells the agent to re-file with the
/// same id and explicitly forbids editing project files. Promotion — asking for
/// real code — is a different builder and a different button, never this one.
public enum StudioFeedbackPromptBuilder {
  /// One element's batched Edit-mode changes, already stamped with its variant.
  public struct ElementEdits: Equatable {
    public let element: ElementInspectorData
    public let variantName: String?
    /// `WebPreviewDesignEditPromptComposer`-style delta lines ("- color: a → b").
    public let changeLines: [String]

    public init(element: ElementInspectorData, variantName: String?, changeLines: [String]) {
      self.element = element
      self.variantName = variantName
      self.changeLines = changeLines
    }
  }

  /// Prompt for a batch of live design edits made in Edit mode.
  public static func editsPrompt(artifact: StudioArtifact, edits: [ElementEdits]) -> String? {
    guard !edits.isEmpty else { return nil }
    let tool = artifact.kind == .canvas ? "agenthub_design" : "agenthub_artifact"
    let noun = artifact.kind == .canvas ? "design canvas" : "artifact"

    var lines: [String] = [
      "I made \(edits.count == 1 ? "a visual edit" : "visual edits") directly on the Studio \(noun) \"\(artifact.title)\" (id \(artifact.id)). Please make them permanent.",
      "",
    ]
    for (index, entry) in edits.enumerated() {
      var heading = "### Element \(index + 1)"
      if let variantName = entry.variantName, !variantName.isEmpty {
        heading += " — variant \"\(variantName)\""
      }
      lines.append(heading)
      lines.append(ElementInspectorPromptBuilder.buildContextPrompt(element: entry.element))
      lines.append("")
      lines.append("Apply these design changes to this element:")
      lines.append(contentsOf: entry.changeLines)
      lines.append("")
    }
    lines.append("Re-file with \(tool) using id \(artifact.id) so it refreshes in place, keeping everything I did not touch exactly as it is.")
    lines.append("This is a scratch surface: do not edit project files for this request.")
    return lines.joined(separator: "\n")
  }

  /// Prompt for a crop-selected region (screenshot + the elements inside it).
  public static func cropPrompt(
    artifact: StudioArtifact,
    variantName: String?,
    cropRect: CGRect,
    elements: [ElementInspectorData],
    instruction: String,
    screenshotPath: String?
  ) -> String {
    let tool = artifact.kind == .canvas ? "agenthub_design" : "agenthub_artifact"
    let noun = artifact.kind == .canvas ? "design canvas" : "artifact"
    var opening = "I'm looking at a region of the Studio \(noun) \"\(artifact.title)\" you rendered with \(tool) (id \(artifact.id))"
    if let variantName, !variantName.isEmpty { opening += ", on variant \"\(variantName)\"" }
    opening += "."
    let body = ElementInspectorPromptBuilder.buildCropPrompt(
      cropRect: cropRect,
      elements: elements,
      instruction: instruction,
      screenshotPath: screenshotPath
    )
    // The Canvas builder opens with a web-preview line; keep its region/image/
    // elements body under Studio's own framing.
    let trimmedBody = body
      .replacingOccurrences(of: "I'm looking at a selected region in the live web preview:\n\n", with: "")
    return [
      opening,
      "",
      trimmedBody,
      "",
      "Update the \(noun) and re-file it with \(tool) using id \(artifact.id) so it refreshes in place.",
      "This is a scratch surface: do not edit project files for this request.",
    ].joined(separator: "\n")
  }

  public static func prompt(
    artifact: StudioArtifact,
    variantName: String?,
    element: ElementInspectorData?,
    instruction: String
  ) -> String {
    let tool = artifact.kind == .canvas ? "agenthub_design" : "agenthub_artifact"
    let noun = artifact.kind == .canvas ? "design canvas" : "artifact"

    var lines: [String] = []
    var opening = "I'm looking at the Studio \(noun) \"\(artifact.title)\" you rendered with \(tool) (id \(artifact.id))"
    if let variantName, !variantName.isEmpty {
      opening += ", variant \"\(variantName)\""
    }
    opening += "."
    lines.append(opening)
    lines.append("")

    if let element {
      lines.append(ElementInspectorPromptBuilder.buildContextPrompt(element: element))
      lines.append("")
    }

    lines.append("User request: \(instruction)")
    lines.append("")

    if artifact.kind == .canvas {
      var closing = "Update the canvas and re-file it with \(tool) using id \(artifact.id) so it refreshes in place"
      closing += variantName != nil ? " — change the \"\(variantName!)\" variant, keep the other variants as they are unless the request says otherwise." : "."
      lines.append(closing)
    } else {
      lines.append("Update the document and re-file it with \(tool) using id \(artifact.id) so it refreshes in place.")
    }
    lines.append("This is a scratch surface: do not edit project files for this request.")

    return lines.joined(separator: "\n")
  }
}
