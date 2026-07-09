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
  /// plus the loop, no per-task instructions.
  public static let systemPrompt = """
    This project runs inside AgentHub, which embeds a live iOS Simulator the user is \
    watching. For simulator work, use the XcodeBuildMCP server that AgentHub configures \
    for this project instead of raw xcodebuild or simctl. At the start of a verification \
    loop, inspect the XcodeBuildMCP session defaults; if project, scheme, or simulator \
    context is missing, use XcodeBuildMCP discovery/listing tools and set defaults before \
    building. After changing UI code, verify end-to-end with XcodeBuildMCP build/run tools, \
    navigate to the affected screen with its UI automation tools, and confirm the result \
    with its screenshot or UI inspection tools before declaring the change done.
    """
}
