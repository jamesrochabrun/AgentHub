import Foundation
import Testing

@testable import AgentHubCore

@Suite("XcodeBuildMCPPreflight")
struct XcodeBuildMCPPreflightTests {

  @Test("Finds npx on an injected search path")
  func findsNPXOnSearchPath() throws {
    let binDirectory = try makeTemporaryDirectory(named: "PreflightNPX")
    defer { try? FileManager.default.removeItem(at: binDirectory) }
    try writeExecutable(named: "npx", in: binDirectory)

    #expect(
      XcodeBuildMCPPreflight.nodeToolingAvailable(
        searchPaths: [binDirectory.path],
        homeDirectory: binDirectory
      )
    )
  }

  @Test("Finds a global xcodebuildmcp binary on an injected search path")
  func findsGlobalXcodeBuildMCPBinary() throws {
    let binDirectory = try makeTemporaryDirectory(named: "PreflightBinary")
    defer { try? FileManager.default.removeItem(at: binDirectory) }
    try writeExecutable(named: "xcodebuildmcp", in: binDirectory)

    #expect(
      XcodeBuildMCPPreflight.nodeToolingAvailable(
        searchPaths: [binDirectory.path],
        homeDirectory: binDirectory
      )
    )
  }

  @Test("Finds an nvm-managed npx under the home directory")
  func findsNVMManagedNPX() throws {
    let home = try makeTemporaryDirectory(named: "PreflightNVMHome")
    defer { try? FileManager.default.removeItem(at: home) }
    let nodeBin = home.appendingPathComponent(".nvm/versions/node/v22.1.0/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: nodeBin, withIntermediateDirectories: true)
    try writeExecutable(named: "npx", in: nodeBin)

    #expect(
      XcodeBuildMCPPreflight.nodeToolingAvailable(
        searchPaths: [],
        homeDirectory: home
      )
    )
  }

  @Test("Non-executable files and empty paths report unavailable")
  func nonExecutableFilesReportUnavailable() throws {
    let binDirectory = try makeTemporaryDirectory(named: "PreflightNonExec")
    defer { try? FileManager.default.removeItem(at: binDirectory) }
    try "".write(
      to: binDirectory.appendingPathComponent("npx"),
      atomically: true,
      encoding: .utf8
    )

    #expect(
      !XcodeBuildMCPPreflight.nodeToolingAvailable(
        searchPaths: [binDirectory.path],
        homeDirectory: binDirectory
      )
    )
    #expect(
      !XcodeBuildMCPPreflight.nodeToolingAvailable(
        searchPaths: [],
        homeDirectory: binDirectory
      )
    )
  }

  @Test("Bootstrap setting defaults to enabled and honors an explicit opt-out")
  func settingDefaultsToEnabledAndHonorsOptOut() throws {
    let suiteName = "AgentHubTests.XcodeBuildMCPPreflight.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(XcodeBuildMCPPreflight.isEnabled(defaults: defaults))

    defaults.set(false, forKey: AgentHubDefaults.xcodeBuildMCPEnabled)
    #expect(!XcodeBuildMCPPreflight.isEnabled(defaults: defaults))

    defaults.set(true, forKey: AgentHubDefaults.xcodeBuildMCPEnabled)
    #expect(XcodeBuildMCPPreflight.isEnabled(defaults: defaults))
  }

  private func makeTemporaryDirectory(named prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeExecutable(named name: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(name)
    try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path
    )
  }
}
