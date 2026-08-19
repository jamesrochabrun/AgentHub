//
//  StudioAgentGuidance.swift
//  AgentHub
//
//  System-prompt-level guidance injected into agent sessions so they reach
//  for the Studio tools when the user asks to *see* something. Tool
//  descriptions alone are advisory, and both nouns Studio uses ("design",
//  "artifact") are also claimed by other surfaces the model knows well
//  (a /design skill, an Artifact tool), so without a system-prompt line the
//  model routinely edits project files or publishes elsewhere instead — and
//  the result never appears in the panel the user is watching.
//

import Foundation

public enum StudioAgentGuidance {
  /// Default-on; Settings › Studio can turn the nudge off for users who would
  /// rather trigger Studio explicitly (the `/agenthub-studio` skill stays).
  public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: AgentHubDefaults.studioAgentGuidanceEnabled) as? Bool ?? true
  }

  /// Appended to Claude sessions and passed as Codex developer instructions
  /// whenever the bundled `agenthub` MCP server is attached. Kept compact:
  /// which tool for which ask, list-first, and the one hard boundary.
  public static let systemPrompt = """
    This session runs inside AgentHub, which shows a Studio panel beside it. When the user asks to \
    see, compare, mock up, or explore options, versions, or variants of any UI (a button, card, \
    form, screen, landing page…), or asks "what would it look like", render them with the \
    agenthub_design tool — a canvas of variants — instead of editing project files or publishing \
    elsewhere. When they ask for something visual that is not a UI comparison (a report, diagram, \
    dashboard, mockup page, rendered document), render it with agenthub_artifact. Call \
    agenthub_list_artifacts first when refining something already on screen and re-file with its id \
    so the panel updates in place. Inside AgentHub, prefer these over claude.ai artifacts or the \
    /design skill so the result lands in the panel the user is watching. Feedback that arrives from \
    the Studio panel (comments, crops, tweak requests) asks for a re-file, never for project edits. \
    When the user picks a variant — in the panel (an "Implement" request) or in conversation ("let's \
    go with the ghost one") — call agenthub_get_artifact with that variant and implement exactly \
    the html/css it returns: it includes edits the user made in the panel. Before re-filing an \
    existing canvas, fetch it the same way so you start from what the user has.
    """
}
