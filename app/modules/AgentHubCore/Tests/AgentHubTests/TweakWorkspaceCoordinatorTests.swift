import Foundation
import Testing

@testable import AgentHubCore

@Suite("TweakWorkspaceCoordinator")
struct TweakWorkspaceCoordinatorTests {
  @Test("Applies generated file when target is unchanged")
  func appliesGeneratedFile() async throws {
    let fixture = try makeFixture(contents: "before")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let coordinator = TweakWorkspaceCoordinator(temporaryRootURL: fixture.temporaryURL)
    let transaction = try await coordinator.prepare(targetFileURL: fixture.targetURL)
    try Data("after".utf8).write(to: transaction.workingFileURL)

    let result = try await coordinator.finish(transaction, policy: .flexible)

    #expect(result == .applied)
    #expect(try String(contentsOf: fixture.targetURL, encoding: .utf8) == "after")
  }

  @Test("Preserves a concurrent target edit")
  func preservesConcurrentEdit() async throws {
    let fixture = try makeFixture(contents: "before")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let coordinator = TweakWorkspaceCoordinator(temporaryRootURL: fixture.temporaryURL)
    let transaction = try await coordinator.prepare(targetFileURL: fixture.targetURL)
    try Data("agent edit".utf8).write(to: transaction.workingFileURL)
    try Data("main edit".utf8).write(to: fixture.targetURL)

    let result = try await coordinator.finish(transaction, policy: .flexible)

    #expect(result == .conflict)
    #expect(try String(contentsOf: fixture.targetURL, encoding: .utf8) == "main edit")
  }

  @Test("Additive policy preserves existing controls")
  func additivePolicyPreservesControls() async throws {
    let original = html(props: """
      "warmth": { "label": "Warmth", "type": "slider", "min": 0, "max": 100, "step": 1, "value": 60 }
      """)
    let fixture = try makeFixture(contents: original)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let coordinator = TweakWorkspaceCoordinator(temporaryRootURL: fixture.temporaryURL)
    let transaction = try await coordinator.prepare(targetFileURL: fixture.targetURL)
    let generated = html(props: """
      "warmth": { "label": "Warmth", "type": "slider", "min": 0, "max": 100, "step": 1, "value": 60 },
      "night": { "label": "Night", "type": "toggle", "value": false }
      """)
    try Data(generated.utf8).write(to: transaction.workingFileURL)

    let result = try await coordinator.finish(transaction, policy: .additive)

    #expect(result == .applied)
  }

  @Test("Additive policy rejects removed or mutated controls", arguments: [
    """
    "contrast": { "label": "Contrast", "type": "toggle", "value": false }
    """,
    """
    "warmth": { "label": "Warmth", "type": "slider", "min": 0, "max": 100, "step": 1, "value": 20 }
    """,
  ])
  func additivePolicyRejectsInvalidChanges(generatedProps: String) async throws {
    let original = html(props: """
      "warmth": { "label": "Warmth", "type": "slider", "min": 0, "max": 100, "step": 1, "value": 60 }
      """)
    let fixture = try makeFixture(contents: original)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let coordinator = TweakWorkspaceCoordinator(temporaryRootURL: fixture.temporaryURL)
    let transaction = try await coordinator.prepare(targetFileURL: fixture.targetURL)
    try Data(html(props: generatedProps).utf8).write(to: transaction.workingFileURL)

    await #expect(throws: TweakWorkspaceError.invalidGeneratedTweaks) {
      try await coordinator.finish(transaction, policy: .additive)
    }
    #expect(try String(contentsOf: fixture.targetURL, encoding: .utf8) == original)
  }

  private func html(props: String) -> String {
    """
    <script>
      dc_set_props({
        \(props)
      });
      function render() {}
      dc_on_props_changed = render;
      render();
    </script>
    """
  }

  private func makeFixture(contents: String) throws -> Fixture {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TweakWorkspaceCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    let projectURL = rootURL.appendingPathComponent("project", isDirectory: true)
    let temporaryURL = rootURL.appendingPathComponent("tasks", isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let targetURL = projectURL.appendingPathComponent("index.html")
    try Data(contents.utf8).write(to: targetURL)
    return Fixture(rootURL: rootURL, temporaryURL: temporaryURL, targetURL: targetURL)
  }
}

private struct Fixture {
  let rootURL: URL
  let temporaryURL: URL
  let targetURL: URL
}
