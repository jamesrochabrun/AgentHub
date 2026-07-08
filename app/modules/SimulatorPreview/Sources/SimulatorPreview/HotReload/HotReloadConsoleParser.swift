import Foundation

/// Parses the injection engine's console output (captured from
/// `simctl launch --stdout=<file>`) into `HotReloadEngineEvent`s.
///
/// InjectionLite logs to the app's stdout with an `🔥 InjectionLite: `-style
/// prefix. The exact strings matched first come from InjectionLite's
/// `Reloader`/`Recompiler`/`InjectionBase` sources (pinned in
/// `HotReloadHostPackage`); revisit when bumping that pin. The looser
/// 🔥-prefixed patterns after them are drift insurance only — if the pinned
/// wording changes, reload confirmation keeps working instead of silently
/// degrading every save into timeout → full rebuild. The pins remain the
/// contract and must still be re-verified on every version bump.
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
    // The running binary wasn't linked with -interposable (e.g. it was
    // launched from a plain build and only armed at relaunch): the engine
    // keeps compiling dylibs but nothing ever rebinds into the app, so
    // every "reload" is a silent no-op. Only a full armed rebuild fixes the
    // binary — treat it as a failed injection so the fallback fires.
    if trimmed.contains("No symbols replaced") {
      return .injectionFailed(
        message: "App wasn't built with injection support — rebuilding")
    }

    // ── Tolerant fallbacks (drift insurance; see the type comment) ──────
    if trimmed.hasPrefix("🔥") {
      if trimmed.contains("Watching") {
        return .engineReady
      }
      if trimmed.contains("ompiling"),
         let fileRange = trimmed.range(
           of: #"[A-Za-z0-9_+\-.]+\.swift"#, options: .regularExpression) {
        return .recompiling(fileName: String(trimmed[fileRange]))
      }
      if trimmed.contains("✅"),
         trimmed.contains("eload") || trimmed.contains("nject")
           || trimmed.contains("Rebound"),
         let range = trimmed.range(of: "✅") {
        let summary = trimmed[range.upperBound...]
          .trimmingCharacters(in: .whitespaces)
        return .injected(summary: summary.isEmpty ? "Hot reload complete" : summary)
      }
      if let range = trimmed.range(of: "❌") {
        let message = trimmed[range.upperBound...]
          .trimmingCharacters(in: .whitespaces)
        return .injectionFailed(message: message.isEmpty ? "Injection failed" : message)
      }
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
