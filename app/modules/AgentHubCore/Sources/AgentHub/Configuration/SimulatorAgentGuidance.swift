//
//  SimulatorAgentGuidance.swift
//  AgentHub
//
//  System-prompt-level guidance injected into new agent sessions for Xcode
//  projects. Tool descriptions alone are advisory and agents routinely fall
//  back to raw `xcodebuild build` as "validation" — which neither updates nor
//  verifies the app running in AgentHub's simulator panel. A system-prompt
//  line carries far more weight with the model than a tool description.
//

import Foundation

public enum SimulatorAgentGuidance {
  /// Appended to Claude sessions via `--append-system-prompt` when the
  /// project is an Xcode project. Kept compact: one standing rule plus the
  /// loop, no per-task instructions.
  public static let systemPrompt = """
    This project runs inside AgentHub, which embeds a live iOS Simulator the user is \
    watching. For simulator work always use the agenthub MCP tools, never raw xcodebuild or \
    simctl: agenthub_simulator_run builds & relaunches the app and returns build errors — a \
    bare `xcodebuild build` only compiles and neither updates nor verifies the running app. \
    After changing UI code, verify end-to-end: agenthub_simulator_run, then navigate to the \
    affected screen with agenthub_simulator_tap / agenthub_simulator_swipe \
    (agenthub_simulator_describe_ui lists what is on screen), and confirm the result with \
    agenthub_simulator_screenshot before declaring the change done.
    """
}
