//
//  WebPreviewDesignEditGuidance.swift
//  AgentHub
//
//  The instruction prefix that precedes queued Edit Mode changes so the agent
//  applies them the way the project already writes styles and content instead
//  of inlining literals over variables, tokens, and shared definitions.
//

import Foundation

enum WebPreviewDesignEditGuidance {
  /// Prepended once to any composed prompt that carries visual-editor edits.
  static let preamble = """
    The user made these changes by hand in AgentHub's visual editor and wants them applied to the source.

    Apply them the way this project already writes styles and content:
    - Read the file that owns each value before editing it, and follow the project's own guidance when it exists (CLAUDE.md, AGENTS.md, README, lint/format config).
    - If a value comes from a variable, design token, theme entry, constant, or prop, change it at that definition. Never replace a `var(--token)`, variable, or constant reference with a hard-coded literal.
    - If that definition is shared by other call sites that must keep the old value, add or pick a token instead of inlining, and say what you did.
    - Keep the existing mechanism: Tailwind classes stay Tailwind, CSS modules stay CSS modules, styled-components stay styled-components, plain CSS stays plain CSS. Never migrate one to another.
    - Keep the existing notation: same unit (px/rem/em/%), same color notation (hex vs rgb vs hsl vs token), and the same `clamp()` / `min()` / `max()` shape when one is in use — adjust only the component that has to change.
    - For text, edit the string where it is defined (i18n catalog, constant, content or CMS file, or the markup that owns it). Do not paste a second copy of the string next to the original.
    - Change only what these edits require: no refactors, no reformatting, no reordering or rewriting of unrelated code, and no new files unless the project's convention requires one.
    - The values below describe the intended result, not literal code to paste. Reach them idiomatically.
    - If an edit cannot be applied without breaking one of these rules, stop and explain instead of forcing it.
    """
}
