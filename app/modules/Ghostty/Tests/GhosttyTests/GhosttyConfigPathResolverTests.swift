import AgentHubCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

@testable import Ghostty

@Suite("Ghostty config path resolver")
struct GhosttyConfigPathResolverTests {

  @Test("Returns nil when no config path is saved")
  func emptyConfigPath() {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }
    let defaults = store.defaults

    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == nil)
  }

  @Test("Returns saved file path when it exists")
  func existingConfigPath() throws {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }
    let defaults = store.defaults
    let configURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-\(UUID().uuidString).conf")
    try "font-size = 14\n".write(to: configURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: configURL) }

    defaults.set(configURL.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)

    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == configURL.path)
  }

  @Test("Ignores missing files and directories")
  func ignoresInvalidPaths() throws {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }
    let defaults = store.defaults
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    defaults.set(directoryURL.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)
    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == nil)

    defaults.set(directoryURL.appendingPathComponent("missing").path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)
    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == nil)
  }

  #if canImport(Darwin)
  @Test("Ignores non-regular files")
  func ignoresNonRegularFiles() throws {
    let store = GhosttyTestDefaults()
    defer { store.cleanUp() }
    let defaults = store.defaults
    let fifoURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-config-\(UUID().uuidString).fifo")
    let created = fifoURL.path.withCString { mkfifo($0, mode_t(0o600)) }
    try #require(created == 0)
    defer { unlink(fifoURL.path) }

    defaults.set(fifoURL.path, forKey: AgentHubDefaults.terminalGhosttyConfigPath)

    #expect(GhosttyConfigPathResolver.configuredPath(defaults: defaults) == nil)
  }
  #endif
}
