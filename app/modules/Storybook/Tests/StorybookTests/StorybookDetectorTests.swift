import Foundation
import Testing

@testable import Storybook

@Suite("StorybookDetector")
struct StorybookDetectorTests {

  // MARK: - hasStorybook

  @Test("Detects storybook via .storybook directory")
  func detectsViaDirectory() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    #expect(!StorybookDetector.hasStorybook(at: dir.path))

    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent(".storybook"),
      withIntermediateDirectories: true
    )

    #expect(StorybookDetector.hasStorybook(at: dir.path))
  }

  @Test("Detects storybook via package.json storybook script")
  func detectsViaScript() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    {
      "scripts": { "dev": "vite", "storybook": "storybook dev -p 6006" }
    }
    """)

    #expect(StorybookDetector.hasStorybook(at: dir.path))
  }

  @Test("Detects storybook via @storybook/ devDependency")
  func detectsViaDevDependency() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    {
      "devDependencies": { "@storybook/react": "^7.0.0", "typescript": "^5.0.0" }
    }
    """)

    #expect(StorybookDetector.hasStorybook(at: dir.path))
  }

  @Test("Returns false when no storybook indicators present")
  func returnsFalseWithoutStorybook() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    {
      "scripts": { "dev": "vite" },
      "devDependencies": { "vite": "^5.0.0" }
    }
    """)

    #expect(!StorybookDetector.hasStorybook(at: dir.path))
  }

  @Test("Returns false for nonexistent path")
  func returnsFalseForBadPath() {
    #expect(!StorybookDetector.hasStorybook(at: "/nonexistent/\(UUID().uuidString)"))
  }

  // MARK: - storybookScript

  @Test("Returns storybook script name from package.json")
  func returnsScriptName() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    {
      "scripts": { "storybook": "storybook dev -p 6006" }
    }
    """)

    #expect(StorybookDetector.storybookScript(at: dir.path) == "storybook")
  }

  @Test("Falls back to storybook:dev script")
  func fallsBackToStorybookDev() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    {
      "scripts": { "storybook:dev": "start-storybook -p 6006" }
    }
    """)

    #expect(StorybookDetector.storybookScript(at: dir.path) == "storybook:dev")
  }

  @Test("Returns nil when no storybook script")
  func returnsNilWithoutScript() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    { "scripts": { "dev": "vite" } }
    """)

    #expect(StorybookDetector.storybookScript(at: dir.path) == nil)
  }

  // MARK: - Constants

  @Test("Default port is 6006")
  func defaultPort() {
    #expect(StorybookDetector.defaultPort == 6006)
  }

  // MARK: - storybookScriptPort

  @Test("Parses port from `-p 6006` form")
  func parsesShortFormPort() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    { "scripts": { "storybook": "storybook dev -p 6006" } }
    """)

    #expect(StorybookDetector.storybookScriptPort(at: dir.path) == 6006)
  }

  @Test("Parses port from `--port 7007` form")
  func parsesLongFormPort() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    { "scripts": { "storybook": "storybook dev --port 7007" } }
    """)

    #expect(StorybookDetector.storybookScriptPort(at: dir.path) == 7007)
  }

  @Test("Parses port from `-p=8008` equals form")
  func parsesEqualsFormPort() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    { "scripts": { "storybook": "storybook dev -p=8008" } }
    """)

    #expect(StorybookDetector.storybookScriptPort(at: dir.path) == 8008)
  }

  @Test("Returns nil when script has no port flag")
  func returnsNilWithoutPort() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    { "scripts": { "storybook": "storybook dev" } }
    """)

    #expect(StorybookDetector.storybookScriptPort(at: dir.path) == nil)
  }

  @Test("Does not match `--no-port-flag` decoy strings")
  func ignoresFalsePositives() throws {
    let dir = makeTestDir()
    defer { cleanup(dir) }

    try writePackageJSON(to: dir, content: """
    { "scripts": { "storybook": "storybook dev --no-disable-telemetry" } }
    """)

    #expect(StorybookDetector.storybookScriptPort(at: dir.path) == nil)
  }

  // MARK: - Helpers

  private func makeTestDir() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("storybook-test-\(UUID().uuidString)")
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func writePackageJSON(to dir: URL, content: String) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try content.write(
      to: dir.appendingPathComponent("package.json"),
      atomically: true,
      encoding: .utf8
    )
  }
}
