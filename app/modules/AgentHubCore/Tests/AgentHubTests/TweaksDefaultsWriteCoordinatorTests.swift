import Canvas
import Foundation
import Testing

@testable import AgentHubCore

private actor TweaksMockFileService: ProjectFileServiceProtocol {
  struct WriteCall: Equatable, Sendable {
    let path: String
    let content: String
  }

  enum MockError: Error {
    case missingFile
  }

  private var files: [String: String]
  private var writes: [WriteCall] = []

  init(files: [String: String]) {
    self.files = files
  }

  func readFile(at path: String, projectPath: String) async throws -> String {
    guard let content = files[path] else { throw MockError.missingFile }
    return content
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    files[path] = content
    writes.append(WriteCall(path: path, content: content))
  }

  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String] {
    files.keys.sorted()
  }

  func recordedWrites() -> [WriteCall] {
    writes
  }
}

@Suite("TweaksDefaultsWriteCoordinator")
struct TweaksDefaultsWriteCoordinatorTests {
  private let filePath = "/project/index.html"
  private let html = """
  <script>
    dc_set_props({
      "warmth": { "label": "Warmth", "type": "slider", "min": 0, "max": 100, "step": 1, "value": 60 },
      "accent": { "label": "Accent", "type": "color", "value": "#ff6b35" }
    });
  </script>
  """

  @Test("Writes a declared prop value into the source")
  func writesDeclaredPropValue() async throws {
    let fileService = TweaksMockFileService(files: [filePath: html])
    let coordinator = TweaksDefaultsWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.writeValue(
      propName: "warmth",
      value: .number(72),
      filePath: filePath,
      projectPath: "/project"
    )

    #expect(outcome == .written)
    let writes = await fileService.recordedWrites()
    #expect(writes.count == 1)
    #expect(writes.first?.content.contains("\"value\": 72") == true)
    #expect(writes.first?.content.contains(
      "\"accent\": { \"label\": \"Accent\", \"type\": \"color\", \"value\": \"#ff6b35\" }"
    ) == true)
  }

  @Test("Rejects undeclared prop names without writing")
  func rejectsUndeclaredPropName() async throws {
    let fileService = TweaksMockFileService(files: [filePath: html])
    let coordinator = TweaksDefaultsWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.writeValue(
      propName: "missing",
      value: .string("retro"),
      filePath: filePath,
      projectPath: "/project"
    )

    #expect(outcome == .propNotDeclared)
    let writes = await fileService.recordedWrites()
    #expect(writes.isEmpty)
  }

  @Test("Rejects unsafe prop names before parsing")
  func rejectsUnsafePropName() async throws {
    let fileService = TweaksMockFileService(files: [filePath: html])
    let coordinator = TweaksDefaultsWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.writeValue(
      propName: "warmth;alert(1)",
      value: .number(72),
      filePath: filePath,
      projectPath: "/project"
    )

    #expect(outcome == .invalidPropName)
    let writes = await fileService.recordedWrites()
    #expect(writes.isEmpty)
  }
}

@Suite("WebPreviewFileWatcher reload suppression")
@MainActor
struct WebPreviewFileWatcherSuppressionTests {
  @Test("Suppression lasts until the requested date and then clears")
  func suppressionWindowClearsAfterDate() {
    let watcher = WebPreviewFileWatcher()
    let now = Date()

    watcher.suppressReloads(until: now.addingTimeInterval(1))

    #expect(watcher.isReloadSuppressed(at: now.addingTimeInterval(0.5)))
    #expect(watcher.isReloadSuppressed(at: now.addingTimeInterval(1.1)) == false)
    #expect(watcher.isReloadSuppressed(at: now.addingTimeInterval(1.2)) == false)
  }

  @Test("Later suppression windows extend the active suppression")
  func suppressionWindowExtends() {
    let watcher = WebPreviewFileWatcher()
    let now = Date()

    watcher.suppressReloads(until: now.addingTimeInterval(1))
    watcher.suppressReloads(until: now.addingTimeInterval(2))

    #expect(watcher.isReloadSuppressed(at: now.addingTimeInterval(1.5)))
    #expect(watcher.isReloadSuppressed(at: now.addingTimeInterval(2.1)) == false)
  }
}
