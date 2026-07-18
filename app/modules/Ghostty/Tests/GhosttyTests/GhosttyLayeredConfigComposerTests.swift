import AgentHubCore
import Foundation
import Testing

@testable import Ghostty

@Suite("Ghostty layered config composer")
struct GhosttyLayeredConfigComposerTests {

  @Test("Returns nil when no custom config is set")
  func noCustomConfig() {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }

    #expect(GhosttyLayeredConfigComposer.effectiveConfigPath(defaults: store.defaults) == nil)
  }

  @Test("Returns nil when the custom path is invalid")
  func invalidCustomPath() {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }
    store.defaults.set("/nonexistent/\(UUID().uuidString)", forKey: AgentHubDefaults.terminalGhosttyConfigPath)

    #expect(GhosttyLayeredConfigComposer.effectiveConfigPath(defaults: store.defaults) == nil)
  }

  @Test("Generates a layered config: default locations first, custom file last")
  func layeredGeneration() throws {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let customURL = tempDir.appendingPathComponent("custom.conf")
    try "cursor-style = bar\n".write(to: customURL, atomically: true, encoding: .utf8)
    store.defaults.set(customURL.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)

    let home = tempDir.appendingPathComponent("home", isDirectory: true)
    let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)

    let path = try #require(GhosttyLayeredConfigComposer.effectiveConfigPath(
      defaults: store.defaults,
      environment: [:],
      homeDirectoryURL: home,
      outputDirectoryURL: outputDir
    ))

    #expect(path == outputDir.appendingPathComponent("embedded-config").path)

    let content = try String(contentsOfFile: path, encoding: .utf8)
    let includes = content
      .split(separator: "\n")
      .filter { $0.hasPrefix("config-file = ") }
      .map(String.init)

    #expect(includes == [
      "config-file = ?\(home.path)/.config/ghostty/config",
      "config-file = ?\(home.path)/Library/Application Support/com.mitchellh.ghostty/config",
      "config-file = ?\(customURL.path)",
    ])
  }

  @Test("Respects XDG_CONFIG_HOME for the default config location")
  func xdgConfigHome() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let paths = GhosttyLayeredConfigComposer.defaultConfigPaths(
      environment: ["XDG_CONFIG_HOME": "/custom/xdg"],
      homeDirectoryURL: home
    )

    #expect(paths == [
      "/custom/xdg/ghostty/config",
      "/Users/example/Library/Application Support/com.mitchellh.ghostty/config",
    ])
  }

  @Test("Does not include the custom file twice when it is a default location")
  func dedupesDefaultLocation() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let appSupportConfig = "/Users/example/Library/Application Support/com.mitchellh.ghostty/config"

    let content = GhosttyLayeredConfigComposer.layeredConfigContent(
      customPath: appSupportConfig,
      environment: [:],
      homeDirectoryURL: home
    )

    let occurrences = content.components(separatedBy: appSupportConfig).count - 1
    #expect(occurrences == 1)
    #expect(content.hasSuffix("config-file = ?\(appSupportConfig)\n"))
  }

  @Test("Falls back to the custom path when the generated file cannot be written")
  func fallbackOnWriteFailure() throws {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let customURL = tempDir.appendingPathComponent("custom.conf")
    try "cursor-style = bar\n".write(to: customURL, atomically: true, encoding: .utf8)
    store.defaults.set(customURL.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)

    let blockerURL = tempDir.appendingPathComponent("blocker")
    try Data().write(to: blockerURL)

    let path = GhosttyLayeredConfigComposer.effectiveConfigPath(
      defaults: store.defaults,
      environment: [:],
      homeDirectoryURL: tempDir,
      outputDirectoryURL: blockerURL.appendingPathComponent("nested", isDirectory: true)
    )

    #expect(path == customURL.path)
  }
}

private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ghostty-layered-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
