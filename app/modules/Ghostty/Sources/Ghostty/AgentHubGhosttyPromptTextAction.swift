import Foundation

/// Builds Ghostty `text:` binding actions for prompt submission.
///
/// `ghostty_surface_text` is libghostty's IME text-input path and sanitizes
/// control bytes: the ESC of a bracketed-paste marker is dropped and the
/// remaining `[200~` / `[201~` are typed into the child app as literal text.
/// The `text:` binding action instead decodes Zig string-literal escapes and
/// writes the bytes straight to the pty, so the markers survive intact.
enum AgentHubGhosttyPromptTextAction {
  /// The binding action that pastes `text` wrapped in bracketed-paste markers.
  static func bracketedPaste(_ text: String) -> String {
    "text:\\x1b[200~" + escaped(text) + "\\x1b[201~"
  }

  /// Escapes `text` as Zig string-literal content: backslashes, double quotes,
  /// and control characters become escape sequences; everything else passes
  /// through as UTF-8. Ghostty evaluates the action's payload as a quoted Zig
  /// string literal, so an unescaped quote would truncate the prompt.
  static func escaped(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\":
        out += "\\\\"
      case "\"":
        out += "\\\""
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F {
          out += String(format: "\\x%02x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out
  }
}
