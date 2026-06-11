import Testing

@testable import SimulatorPreview

@Suite("HotReloadConsoleParser")
struct HotReloadConsoleParserTests {

  private let parser = HotReloadConsoleParser()

  @Test("engine ready line")
  func engineReady() {
    let line = "🔥 InjectionLite: Watching for source changes under /Users/dev/App/..., /Users/dev/Library/..."
    #expect(parser.parse(line: line) == .engineReady)
  }

  @Test("recompiling line extracts the file name")
  func recompiling() {
    let line = "🔥 🔄 [HomeView.swift] Recompiling"
    #expect(parser.parse(line: line) == .recompiling(fileName: "HomeView.swift"))
  }

  @Test("successful injection")
  func injected() {
    let line = "🔥 ✅ Hot reload complete - Rebound 12 symbols, classes (new: 0, old: 1)"
    #expect(parser.parse(line: line) ==
      .injected(summary: "Hot reload complete - Rebound 12 symbols, classes (new: 0, old: 1)"))
  }

  @Test("compilation failure")
  func compilationFailed() {
    let line = "🔥 ❌ Compilation failed:"
    #expect(parser.parse(line: line) == .injectionFailed(message: "Compilation failed"))
  }

  @Test("file missing from build log needs a rebuild")
  func missingCommand() {
    let line = "🔥 ⚠️ Could not locate command for /Users/dev/App/NewView.swift. Try rebuilding."
    #expect(parser.parse(line: line) ==
      .injectionFailed(message: "File not in the current build — rebuilding"))
  }

  @Test("type layout change blocks injection")
  func layoutChanged() {
    let line = "🔥 ⚠️ Size of a type changed over injection, this will likely fail and this injection is blocked."
    #expect(parser.parse(line: line) ==
      .injectionFailed(message: "Stored-property layout changed — rebuilding"))
  }

  @Test("missing interposable flag surfaces as warning")
  func noSymbolsReplaced() {
    let line = "🔥 ℹ️ No symbols replaced, have you added -Xlinker -interposable to your project?"
    #expect(parser.parse(line: line) ==
      .warning(message: "Injection loaded but no symbols were replaced"))
  }

  @Test("generic engine warning becomes a warning event")
  func genericWarning() {
    let line = "🔥 ⚠️ INJECTION_DIRECTORIES should contain ~/Library"
    #expect(parser.parse(line: line) ==
      .warning(message: "INJECTION_DIRECTORIES should contain ~/Library"))
  }

  @Test("plain app output is ignored")
  func appOutput() {
    #expect(parser.parse(line: "User tapped the buy button") == nil)
    #expect(parser.parse(line: "") == nil)
    #expect(parser.parse(line: "⚠️ app's own warning") == nil)
  }
}
