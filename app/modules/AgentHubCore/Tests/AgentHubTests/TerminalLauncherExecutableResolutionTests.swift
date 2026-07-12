import Foundation
import Testing

@testable import AgentHubCore

@Suite("TerminalLauncher executable resolution")
struct TerminalLauncherExecutableResolutionTests {
  @Test("Accepts executable absolute command paths")
  func acceptsExecutableAbsoluteCommandPaths() throws {
    let executable = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-executable-\(UUID().uuidString)")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    #expect(TerminalLauncher.findExecutable(command: executable.path, additionalPaths: []) == executable.path)
  }
}
