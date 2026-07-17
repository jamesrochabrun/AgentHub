import Foundation
import Testing

@testable import AgentHubCore

@Suite("Ghostty user theme scanner")
struct GhosttyUserThemeScannerTests {

  @Test("Resolves nothing when no config files exist")
  func noConfigFiles() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }

    #expect(env.resolve() == .none)
  }

  @Test("Explicit hex background applies to both modes")
  func explicitBackground() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeAppSupportConfig("background = #1E1E2E\n")

    let background = env.resolve()
    #expect(background == GhosttyUserBackground(lightHex: "#1e1e2e", darkHex: "#1e1e2e"))
    #expect(background.adoptableHex(isDark: true) == "#1e1e2e")
    #expect(background.adoptableHex(isDark: false) == nil)
  }

  @Test("Split theme resolves per-mode backgrounds from theme files")
  func splitTheme() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeTheme(named: "Latte", contents: "background = eff1f5\nforeground = 4c4f69\n")
    try env.writeTheme(named: "Mocha", contents: "background = 1e1e2e\nforeground = cdd6f4\n")
    try env.writeAppSupportConfig("theme = light:Latte,dark:Mocha\n")

    let background = env.resolve()
    #expect(background == GhosttyUserBackground(lightHex: "#eff1f5", darkHex: "#1e1e2e"))
    #expect(background.adoptableHex(isDark: false) == "#eff1f5")
    #expect(background.adoptableHex(isDark: true) == "#1e1e2e")
  }

  @Test("Single theme name applies to both modes, filtered by luminance")
  func singleTheme() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeTheme(named: "Mocha", contents: "background = 1e1e2e\n")
    try env.writeAppSupportConfig("theme = Mocha\n")

    let background = env.resolve()
    #expect(background == GhosttyUserBackground(lightHex: "#1e1e2e", darkHex: "#1e1e2e"))
    #expect(background.adoptableHex(isDark: true) == "#1e1e2e")
    #expect(background.adoptableHex(isDark: false) == nil)
  }

  @Test("Explicit background wins over the theme")
  func explicitOverridesTheme() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeTheme(named: "Mocha", contents: "background = 1e1e2e\n")
    try env.writeAppSupportConfig("background = #101010\ntheme = Mocha\n")

    #expect(env.resolve() == GhosttyUserBackground(lightHex: "#101010", darkHex: "#101010"))
  }

  @Test("Empty background resets back to the theme")
  func emptyBackgroundResets() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeTheme(named: "Mocha", contents: "background = 1e1e2e\n")
    try env.writeAppSupportConfig("background = #101010\ntheme = Mocha\nbackground =\n")

    #expect(env.resolve() == GhosttyUserBackground(lightHex: "#1e1e2e", darkHex: "#1e1e2e"))
  }

  @Test("Unparseable background resolves to no adoption")
  func namedColorBackground() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeTheme(named: "Mocha", contents: "background = 1e1e2e\n")
    try env.writeAppSupportConfig("theme = Mocha\nbackground = red\n")

    #expect(env.resolve() == .none)
  }

  @Test("config-file includes are followed and later files win")
  func includesFollowed() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.write("extra.conf", inAppSupport: true, contents: "background = #222222\n")
    try env.writeAppSupportConfig(
      "background = #111111\nconfig-file = extra.conf\nconfig-file = ?missing.conf\n"
    )

    #expect(env.resolve().darkHex == "#222222")
  }

  @Test("Include cycles terminate")
  func includeCycle() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.write("a.conf", inAppSupport: true, contents: "config-file = b.conf\nbackground = #111111\n")
    try env.write("b.conf", inAppSupport: true, contents: "config-file = a.conf\n")
    try env.writeAppSupportConfig("config-file = a.conf\n")

    #expect(env.resolve().darkHex == "#111111")
  }

  @Test("Custom config from Settings layers on top of default files")
  func customConfigWins() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeAppSupportConfig("background = #111111\n")
    try env.setCustomConfig("background = #333333\n")

    #expect(env.resolve().darkHex == "#333333")
  }

  @Test("Quoted theme values and bundled theme directory resolution")
  func quotedThemeAndBundledDirectory() throws {
    let env = try ScannerEnvironment()
    defer { env.cleanUp() }
    try env.writeBundledTheme(named: "Catppuccin Mocha", contents: "background = 1e1e2e\n")
    try env.writeAppSupportConfig("theme = \"Catppuccin Mocha\"\n")

    #expect(env.resolve().darkHex == "#1e1e2e")
  }
}

/// Sandboxed home directory + defaults suite for scanner tests.
private struct ScannerEnvironment {
  let home: URL
  let defaults: UserDefaults
  private let suiteName: String
  private let bundledThemesURL: URL

  init() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-scanner-\(UUID().uuidString)", isDirectory: true)
    bundledThemesURL = home.appendingPathComponent("bundled-themes", isDirectory: true)
    try FileManager.default.createDirectory(at: bundledThemesURL, withIntermediateDirectories: true)
    suiteName = "com.agenthub.tests.ghostty-scanner.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: home)
  }

  func resolve() -> GhosttyUserBackground {
    GhosttyUserThemeScanner.resolveBackground(
      defaults: defaults,
      environment: [:],
      homeDirectoryURL: home,
      bundledThemesDirectoryURL: bundledThemesURL,
      includeSystemThemeDirectories: false
    )
  }

  private var appSupportGhostty: URL {
    home
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
  }

  func writeAppSupportConfig(_ contents: String) throws {
    try write("config", inAppSupport: true, contents: contents)
  }

  func write(_ name: String, inAppSupport: Bool, contents: String) throws {
    let directory = inAppSupport ? appSupportGhostty : home
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try contents.write(
      to: directory.appendingPathComponent(name),
      atomically: true,
      encoding: .utf8
    )
  }

  func writeTheme(named name: String, contents: String) throws {
    let themes = appSupportGhostty.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try contents.write(to: themes.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  func writeBundledTheme(named name: String, contents: String) throws {
    try contents.write(
      to: bundledThemesURL.appendingPathComponent(name),
      atomically: true,
      encoding: .utf8
    )
  }

  func setCustomConfig(_ contents: String) throws {
    let url = home.appendingPathComponent("custom.conf")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    defaults.set(url.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)
  }
}
