//
//  SimulatorAgentGuidance.swift
//  AgentHub
//
//  System-prompt-level guidance injected into new agent sessions for Xcode
//  projects. Tool descriptions alone are advisory and agents routinely fall
//  back to raw `xcodebuild build` as "validation", which neither updates nor
//  verifies the app running in AgentHub's simulator panel. A system-prompt
//  line carries far more weight with the model than a tool description.
//

import Foundation

public enum SimulatorAgentGuidance {
  /// Appended to Claude sessions and passed as Codex developer instructions
  /// when the project is an Xcode project. Kept compact: one standing rule
  /// plus a proportional verification ladder — the depth decision is the
  /// model's, made per-claim from the user's intent.
  public static let systemPrompt = """
    This project runs inside AgentHub, which embeds a live iOS Simulator the user is \
    watching. For simulator work, use the XcodeBuildMCP server that AgentHub configures \
    for this project instead of raw xcodebuild or simctl. Before the first build, inspect \
    the XcodeBuildMCP session defaults; if project, scheme, or simulator context is \
    missing, set them with its discovery tools. Scale verification to the change and the \
    user's intent: a compile check is enough for refactors and non-visual changes; build \
    and run when runtime behavior changes, so the simulator the user is watching stays \
    current; drive the UI with automation and confirm with screenshots or UI inspection \
    only when the user asked for visual or end-to-end verification, or before claiming a \
    specific visual result looks right. The full loop is slow and token-expensive — \
    don't run it by default.
    """
}
