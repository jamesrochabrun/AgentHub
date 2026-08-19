import AgentHubCLIKit
import Canvas
import Foundation

/// Prompts for the Tweaks panel's agent actions on a Studio artifact.
///
/// Web preview runs a headless agent that edits the previewed file on disk.
/// Studio has no such file — the served document is a cache of the payload —
/// so every action goes back through the *session* as a re-file request, on
/// the same rails as Send. The agent re-files with the same id and the panel
/// updates in place.
public enum StudioTweaksPromptBuilder {
  public static func ideasPrompt(artifact: StudioArtifact, existingProps: [TweakProp]) -> String {
    let existing = existingProps.isEmpty
      ? "There are no tweakable props yet."
      : "Existing props (keep them exactly as they are): " + existingProps.map { "\($0.name) (\($0.type.rawValue))" }.joined(separator: ", ") + "."
    return """
    Add two or three new tweakable controls to the Studio \(noun(artifact)) "\(artifact.title)" (id \(artifact.id)) — expressive knobs that reshape the feel (density, tone, emphasis, motion), not single-pixel adjustments, and meaningfully different from every existing control.
    \(existing)

    \(contract(artifact))
    """
  }

  public static func customPrompt(artifact: StudioArtifact, instruction: String) -> String {
    """
    Add tweakable controls to the Studio \(noun(artifact)) "\(artifact.title)" (id \(artifact.id)): \(instruction)

    \(contract(artifact))
    """
  }

  public static func deleteAllPrompt(artifact: StudioArtifact) -> String {
    let how = artifact.kind == .canvas
      ? "Re-file with agenthub_design using id \(artifact.id) with no `props`, and replace every var(--<name>) in the variants' CSS with the current default value so every variant looks exactly as it does now."
      : "Re-file with agenthub_artifact using id \(artifact.id) with the dc_set_props call, dc_on_props_changed, and every prop read removed, hard-coding the current default values so the document looks and behaves exactly as it does now."
    return """
    Remove all tweakable controls from the Studio \(noun(artifact)) "\(artifact.title)" (id \(artifact.id)). \(how)
    This is a scratch surface: do not edit project files.
    """
  }

  private static func noun(_ artifact: StudioArtifact) -> String {
    artifact.kind == .canvas ? "design canvas" : "artifact"
  }

  private static func contract(_ artifact: StudioArtifact) -> String {
    switch artifact.kind {
    case .canvas:
      return """
      Re-file the canvas with agenthub_design using id \(artifact.id): keep every variant and existing prop unchanged, extend `props` with the new controls (one shared schema for the whole canvas — each prop becomes the CSS custom property --<name> on every artboard, slider values carry their `unit`), and update the variants' CSS to read var(--<name>) so the controls visibly change every variant. Text/select props also fill elements marked data-prop="<name>". This is a scratch surface: do not edit project files.
      """
    case .document:
      return """
      Re-file the document with agenthub_artifact using id \(artifact.id): keep everything else unchanged, extend the existing dc_set_props object literal in place (preserve every existing prop's name, label, type, range/options, default, and order), read the new values via window.props.<name> or dc_on_props_changed, and drive them into the DOM/CSS so they visibly change the design. This is a scratch surface: do not edit project files.
      """
    }
  }
}
