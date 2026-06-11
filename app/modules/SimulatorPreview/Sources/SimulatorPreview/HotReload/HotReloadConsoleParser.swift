import Foundation

/// Parses the injection engine's console output (captured from
/// `simctl launch --stdout=<file>`) into `HotReloadEngineEvent`s.
///
/// InjectionLite logs to the app's stdout with an `🔥 InjectionLite: `-style
/// prefix. The exact strings matched here come from InjectionLite's
/// `Reloader`/`Recompiler`/`InjectionBase` sources (pinned in
/// `HotReloadHostPackage`); revisit when bumping that pin.
public struct HotReloadConsoleParser: Sendable {

  public init() {}

  /// Returns the event encoded in one console line, or nil for lines that
  /// are not injection diagnostics (regular app output passes through).
  public func parse(line: String) -> HotReloadEngineEvent? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // "🔥 InjectionLite: Watching for source changes under /path/..."
    if trimmed.contains("Watching for source changes under") {
      return .engineReady
    }

    // "🔥 🔄 [HomeView.swift] Recompiling"
    if let range = trimmed.range(of: #"🔄 \[([^\]]+)\]"#, options: .regularExpression) {
      let inner = trimmed[range].dropFirst("🔄 [".count).dropLast(1)
      return .recompiling(fileName: String(inner))
    }

    // "🔥 ✅ Hot reload complete - Rebound 12 symbols, classes …"
    if let range = trimmed.range(of: "✅ Hot reload complete") {
      let summary = trimmed[range.lowerBound...]
        .dropFirst("✅ ".count)
        .trimmingCharacters(in: .whitespaces)
      return .injected(summary: summary)
    }

    // "🔥 ❌ Compilation failed:" — the compiler errors follow on later lines.
    if trimmed.contains("❌ Compilation failed") {
      return .injectionFailed(message: "Compilation failed")
    }

    // "🔥 ⚠️ Could not locate command for /path/File.swift …" — the file was
    // never compiled into the current build log; only a rebuild can pick it up.
    if trimmed.contains("⚠️ Could not locate command for") {
      return .injectionFailed(message: "File not in the current build — rebuilding")
    }

    // "🔥 ⚠️ Size of a type changed over injection, … this injection is blocked."
    if trimmed.contains("Size of a type changed over injection") {
      return .injectionFailed(message: "Stored-property layout changed — rebuilding")
    }

    // "🔥 ℹ️ No symbols replaced, have you added -Xlinker -interposable …"
    if trimmed.contains("No symbols replaced") {
      return .warning(message: "Injection loaded but no symbols were replaced")
    }

    // Any other engine warning ("🔥 … ⚠️ …") surfaces as a tooltip detail.
    if trimmed.hasPrefix("🔥"), let range = trimmed.range(of: "⚠️") {
      let message = trimmed[range.upperBound...]
        .trimmingCharacters(in: .whitespaces)
      return .warning(message: message.isEmpty ? "Injection warning" : message)
    }

    return nil
  }
}
