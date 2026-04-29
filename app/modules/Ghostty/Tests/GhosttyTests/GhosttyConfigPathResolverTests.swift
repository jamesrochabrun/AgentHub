import AgentHubCore
import Foundation
import Testing

@testable import Ghostty

@Suite("Ghostty config path resolver")
struct GhosttyConfigPathResolverTests {

  @Test("Returns nil when no config path is saved")
  func emptyConfigPath() {
    let defaults = makeDefaults()

    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == nil)
  }

  @Test("Returns saved file path when it exists")
  func existingConfigPath() throws {
    let defaults = makeDefaults()
    let configURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-\(UUID().uuidString).conf")
    try "font-size = 14\n".write(to: configURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: configURL) }

    defaults.set(configURL.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)

    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == configURL.path)
  }

  @Test("Ignores missing files and directories")
  func ignoresInvalidPaths() throws {
    let defaults = makeDefaults()
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    defaults.set(directoryURL.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)
    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == nil)

    defaults.set(directoryURL.appendingPathComponent("missing").path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)
    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == nil)
  }
}

private func makeDefaults() -> UserDefaults {
  let suiteName = "com.agenthub.tests.ghostty-config.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
}
