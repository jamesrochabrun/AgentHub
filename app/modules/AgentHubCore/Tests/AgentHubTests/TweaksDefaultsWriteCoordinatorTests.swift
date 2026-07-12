import Canvas
import Foundation
import Testing

@testable import AgentHubCore

private actor TweaksMockFileService: ProjectFileServiceProtocol {
  enum MockError: Error { case missingFile, writeFailed }

  private(set) var files: [String: String]
  private(set) var writeCount = 0
  private var shouldFailWrites = false

  init(files: [String: String]) {
    self.files = files
  }

  func failWrites() {
    shouldFailWrites = true
  }

  func readFile(at path: String, projectPath: String) async throws -> String {
    guard let content = files[path] else { throw MockError.missingFile }
    return content
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    guard !shouldFailWrites else { throw MockError.writeFailed }
    files[path] = content
    writeCount += 1
  }

  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String] {
    files.keys.sorted()
  }
}

@Suite("TweaksDefaultsWriteCoordinator")
struct TweaksDefaultsWriteCoordinatorTests {
  private let filePath = "/project/index.html"
  private let projectPath = "/project"
  private let html = """
  <script>
    dc_set_props({
      "warmth": { "label": "Warmth", "type": "slider", "min": 0, "max": 100, "value": 60 },
      "night": { "label": "Night", "type": "toggle", "value": false }
    });
  </script>
  """

  @Test("Writes all changed defaults atomically")
  func writesChangedDefaults() async throws {
    let service = TweaksMockFileService(files: [filePath: html])
    let coordinator = TweaksDefaultsWriteCoordinator(fileService: service)

    try await coordinator.saveDefaults(
      props: makeProps(warmth: .number(85), night: .boolean(true)),
      filePath: filePath,
      projectPath: projectPath
    )

    #expect(await service.writeCount == 1)
    let content = try #require(await service.files[filePath])
    let props = try TweakPropsSourceEditor.parseProps(fromSource: content)
    #expect(props.first(where: { $0.name == "warmth" })?.value == .number(85))
    #expect(props.first(where: { $0.name == "night" })?.value == .boolean(true))
  }

  @Test("Unchanged values do not write")
  func unchangedValuesDoNotWrite() async throws {
    let service = TweaksMockFileService(files: [filePath: html])
    let coordinator = TweaksDefaultsWriteCoordinator(fileService: service)

    try await coordinator.saveDefaults(
      props: makeProps(),
      filePath: filePath,
      projectPath: projectPath
    )

    #expect(await service.writeCount == 0)
  }

  @Test("Rejects source or schema drift")
  func rejectsSourceDrift() async throws {
    let changedHTML = html.replacingOccurrences(of: "\"value\": 60", with: "\"value\": 70")
    let service = TweaksMockFileService(files: [filePath: changedHTML])
    let coordinator = TweaksDefaultsWriteCoordinator(fileService: service)

    await #expect(throws: TweaksDefaultsWriteError.sourceChanged) {
      try await coordinator.saveDefaults(
        props: makeProps(warmth: .number(85)),
        filePath: filePath,
        projectPath: projectPath
      )
    }
    #expect(await service.writeCount == 0)
  }

  @Test("Reports read and write failures")
  func reportsIOFailures() async throws {
    let missingService = TweaksMockFileService(files: [:])
    let missingCoordinator = TweaksDefaultsWriteCoordinator(fileService: missingService)
    await #expect(throws: TweaksDefaultsWriteError.cannotReadFile) {
      try await missingCoordinator.saveDefaults(
        props: makeProps(warmth: .number(85)),
        filePath: filePath,
        projectPath: projectPath
      )
    }

    let failingService = TweaksMockFileService(files: [filePath: html])
    await failingService.failWrites()
    let failingCoordinator = TweaksDefaultsWriteCoordinator(fileService: failingService)
    do {
      try await failingCoordinator.saveDefaults(
        props: makeProps(warmth: .number(85)),
        filePath: filePath,
        projectPath: projectPath
      )
      Issue.record("Expected a write failure")
    } catch let error as TweaksDefaultsWriteError {
      guard case .writeFailed = error else {
        Issue.record("Expected writeFailed, got \(error)")
        return
      }
    }
  }

  @Test("Resolves file and dev-server preview URLs", arguments: [
    (URL(fileURLWithPath: "/project/page.html"), "/project/page.html"),
    (URL(string: "http://localhost:3000/")!, "/project/index.html"),
    (URL(string: "http://localhost:3000/docs/")!, "/project/docs/index.html"),
    (URL(string: "http://localhost:3000/about.html")!, "/project/about.html"),
  ])
  func resolvesPreviewURL(argument: (URL, String)) {
    #expect(
      TweaksDefaultsWriteCoordinator.resolveFilePath(
        previewURL: argument.0,
        projectPath: projectPath
      ) == argument.1
    )
  }

  private func makeProps(
    warmth: TweakPropValue = .number(60),
    night: TweakPropValue = .boolean(false)
  ) -> [TweakProp] {
    [
      TweakProp(
        name: "warmth",
        label: "Warmth",
        type: .slider,
        minimum: 0,
        maximum: 100,
        value: warmth,
        defaultValue: .number(60)
      ),
      TweakProp(
        name: "night",
        label: "Night",
        type: .toggle,
        value: night,
        defaultValue: .boolean(false)
      ),
    ]
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
