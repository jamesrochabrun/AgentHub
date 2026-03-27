import Foundation
import Testing

@testable import AgentHubCore

@Suite("Storybook Detection")
struct StorybookDetectionTests {

  // MARK: - ProjectFramework.hasStorybook

  @Test("Detects storybook via .storybook directory")
  func detectsStorybookViaDirectory() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("storybook-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // No .storybook/ directory yet
    #expect(!ProjectFramework.hasStorybook(at: tmpDir.path))

    // Create .storybook/ directory
    let storybookDir = tmpDir.appendingPathComponent(".storybook")
    try FileManager.default.createDirectory(at: storybookDir, withIntermediateDirectories: true)

    #expect(ProjectFramework.hasStorybook(at: tmpDir.path))
  }

  @Test("Detects storybook via package.json storybook script")
  func detectsStorybookViaScript() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("storybook-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let packageJson = """
    {
      "name": "test-project",
      "scripts": {
        "dev": "vite",
        "storybook": "storybook dev -p 6006"
      }
    }
    """
    let packageJsonPath = tmpDir.appendingPathComponent("package.json")
    try packageJson.write(to: packageJsonPath, atomically: true, encoding: .utf8)

    #expect(ProjectFramework.hasStorybook(at: tmpDir.path))
  }

  @Test("Detects storybook via @storybook/ devDependency")
  func detectsStorybookViaDevDependency() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("storybook-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let packageJson = """
    {
      "name": "test-project",
      "devDependencies": {
        "@storybook/react": "^7.0.0",
        "typescript": "^5.0.0"
      }
    }
    """
    let packageJsonPath = tmpDir.appendingPathComponent("package.json")
    try packageJson.write(to: packageJsonPath, atomically: true, encoding: .utf8)

    #expect(ProjectFramework.hasStorybook(at: tmpDir.path))
  }

  @Test("Returns false when no storybook indicators present")
  func returnsFalseWhenNoStorybook() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("storybook-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let packageJson = """
    {
      "name": "test-project",
      "scripts": { "dev": "vite" },
      "devDependencies": { "vite": "^5.0.0" }
    }
    """
    let packageJsonPath = tmpDir.appendingPathComponent("package.json")
    try packageJson.write(to: packageJsonPath, atomically: true, encoding: .utf8)

    #expect(!ProjectFramework.hasStorybook(at: tmpDir.path))
  }

  @Test("Returns false for nonexistent path")
  func returnsFalseForNonexistentPath() {
    #expect(!ProjectFramework.hasStorybook(at: "/nonexistent/path/\(UUID().uuidString)"))
  }

  // MARK: - ProjectFramework enum properties

  @Test("Storybook framework requires dev server")
  func storybookRequiresDevServer() {
    #expect(ProjectFramework.storybook.requiresDevServer)
  }
}
