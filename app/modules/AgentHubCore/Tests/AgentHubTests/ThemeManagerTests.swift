import Foundation
import Testing

@testable import AgentHubCore

private final class CountingUserDefaults: UserDefaults, @unchecked Sendable {
  private var setCounts: [String: Int] = [:]

  override func set(_ value: Any?, forKey defaultName: String) {
    setCounts[defaultName, default: 0] += 1
    super.set(value, forKey: defaultName)
  }

  func setCount(forKey key: String) -> Int {
    setCounts[key, default: 0]
  }
}

private final class NoOpThemeFileWatcher: ThemeFileWatching {
  private(set) var watchedURLs: [URL] = []
  private(set) var stoppedURLs: [URL] = []

  func watch(fileURL: URL, onChange: @escaping () -> Void) {
    watchedURLs.append(fileURL)
  }

  func stopWatching(fileURL: URL) {
    stoppedURLs.append(fileURL)
  }
}

private actor RecordingThemeLoadingService: ThemeLoadingServiceProtocol {
  private var discoveredThemes: [DiscoveredYAMLTheme]
  private var loadedThemes: [String: LoadedYAMLTheme]
  private var discoverCallCount = 0
  private var loadCallCount = 0

  init(
    discoveredThemes: [DiscoveredYAMLTheme] = [],
    loadedThemes: [String: LoadedYAMLTheme] = [:]
  ) {
    self.discoveredThemes = discoveredThemes
    self.loadedThemes = loadedThemes
  }

  func discoverThemes(in themesDirectory: URL) async throws -> [DiscoveredYAMLTheme] {
    discoverCallCount += 1
    return discoveredThemes
  }

  func loadTheme(fileURL: URL) async throws -> LoadedYAMLTheme {
    loadCallCount += 1
    let fileName = fileURL.lastPathComponent
    guard let loadedTheme = loadedThemes[fileName] else {
      throw CocoaError(.fileNoSuchFile)
    }
    return loadedTheme
  }

  func setLoadedTheme(_ loadedTheme: LoadedYAMLTheme, for fileName: String) {
    loadedThemes[fileName] = loadedTheme
  }

  func loadCount() -> Int {
    loadCallCount
  }

  func discoverCount() -> Int {
    discoverCallCount
  }
}

private actor DelayedThemeLoadingService: ThemeLoadingServiceProtocol {
  private var continuation: CheckedContinuation<LoadedYAMLTheme, Error>?
  private var loadStarted = false

  func discoverThemes(in themesDirectory: URL) async throws -> [DiscoveredYAMLTheme] {
    []
  }

  func loadTheme(fileURL: URL) async throws -> LoadedYAMLTheme {
    loadStarted = true
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilLoadStarts() async {
    while !loadStarted || continuation == nil {
      await Task.yield()
    }
  }

  func finish(with loadedTheme: LoadedYAMLTheme) {
    continuation?.resume(returning: loadedTheme)
    continuation = nil
  }
}

@Suite("Theme manager", .serialized)
struct ThemeManagerTests {

  @MainActor
  @Test("Initializing the theme manager resolves saved selection without writing defaults")
  func initializingThemeManagerDoesNotWriteDefaults() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }
    fixture.defaults.set("sentry.yaml", forKey: AgentHubDefaults.selectedTheme)
    let selectedThemeWrites = fixture.defaults.setCount(forKey: AgentHubDefaults.selectedTheme)
    let previousThemeWrites = fixture.defaults.setCount(forKey: AgentHubDefaults.previousNonGhosttyTheme)

    _ = fixture.makeManager(loader: RecordingThemeLoadingService())

    #expect(fixture.defaults.setCount(forKey: AgentHubDefaults.selectedTheme) == selectedThemeWrites)
    #expect(fixture.defaults.setCount(forKey: AgentHubDefaults.previousNonGhosttyTheme) == previousThemeWrites)
  }

  @MainActor
  @Test("Selecting a bundled YAML theme does not rediscover all themes")
  func selectingBundledYAMLDoesNotDiscoverThemes() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }
    let loader = RecordingThemeLoadingService(loadedThemes: [
      "sentry.yaml": try loadedTheme(name: "Sentry")
    ])
    let manager = fixture.makeManager(loader: loader)

    let appliedThemeId = await manager.applySelection("sentry.yaml", backend: .regular)

    #expect(appliedThemeId == "sentry.yaml")
    #expect(manager.currentTheme.sourceFileName == "sentry.yaml")
    #expect(await loader.loadCount() == 1)
    #expect(await loader.discoverCount() == 0)
  }

  @MainActor
  @Test("Selecting the current YAML theme does not reload or rewrite defaults")
  func selectingCurrentYAMLDoesNotReload() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }
    let loader = RecordingThemeLoadingService(loadedThemes: [
      "sentry.yaml": try loadedTheme(name: "Sentry")
    ])
    let manager = fixture.makeManager(loader: loader)

    await manager.applySelection("sentry.yaml", backend: .regular)
    let selectedThemeWrites = fixture.defaults.setCount(forKey: AgentHubDefaults.selectedTheme)

    await manager.applySelection("sentry.yaml", backend: .regular)

    #expect(manager.currentTheme.sourceFileName == "sentry.yaml")
    #expect(await loader.loadCount() == 1)
    #expect(fixture.defaults.setCount(forKey: AgentHubDefaults.selectedTheme) == selectedThemeWrites)
  }

  @MainActor
  @Test("A stale YAML load cannot overwrite a newer built-in theme selection")
  func staleYAMLLoadCannotOverwriteNewerSelection() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }
    let loader = DelayedThemeLoadingService()
    let manager = fixture.makeManager(loader: loader)

    let slowSelection = Task { @MainActor in
      await manager.applySelection("slow.yaml", backend: .regular)
    }
    await loader.waitUntilLoadStarts()

    let appliedThemeId = await manager.applySelection("neutral", backend: .regular)
    let loadedSlowTheme = try loadedTheme(name: "Slow", primary: "#AA0000")
    await loader.finish(with: loadedSlowTheme)
    _ = await slowSelection.value

    #expect(appliedThemeId == "neutral")
    #expect(manager.currentTheme.isBuiltIn)
    #expect(manager.currentTheme.id == "neutral")
    #expect(fixture.defaults.string(forKey: AgentHubDefaults.selectedTheme) == "neutral")
  }

  @MainActor
  @Test("Cached YAML loads reuse parsed runtime theme and persisted palette")
  func cachedYAMLLoadReusesRuntimeThemeAndPalette() async throws {
    let fixture = try Fixture()
    defer { fixture.teardown() }
    let loader = RecordingThemeLoadingService(loadedThemes: [
      "cached.yaml": try loadedTheme(
        name: "Cached",
        primary: "#112233",
        secondary: "#445566",
        tertiary: "#778899"
      )
    ])
    let manager = fixture.makeManager(loader: loader)
    let themeURL = fixture.themesDirectory.appendingPathComponent("cached.yaml")

    try await manager.loadTheme(fileURL: themeURL)
    let changedTheme = try loadedTheme(name: "Changed", primary: "#ABCDEF")
    await loader.setLoadedTheme(changedTheme, for: "cached.yaml")
    try await manager.loadTheme(fileURL: themeURL)

    #expect(await loader.loadCount() == 1)
    #expect(manager.currentTheme.name == "Cached")
    #expect(fixture.defaults.string(forKey: AgentHubDefaults.yamlPrimaryHex) == "#112233")
    #expect(fixture.defaults.string(forKey: AgentHubDefaults.yamlSecondaryHex) == "#445566")
    #expect(fixture.defaults.string(forKey: AgentHubDefaults.yamlTertiaryHex) == "#778899")
  }

  private final class Fixture {
    let themesDirectory: URL
    let suiteName: String
    let defaults: CountingUserDefaults

    init() throws {
      self.themesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ThemeManagerTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)

      self.suiteName = "ThemeManagerTests.\(UUID().uuidString)"
      guard let defaults = CountingUserDefaults(suiteName: suiteName) else {
        throw CocoaError(.fileNoSuchFile)
      }
      defaults.removePersistentDomain(forName: suiteName)
      self.defaults = defaults
    }

    @MainActor
    func makeManager(loader: any ThemeLoadingServiceProtocol) -> ThemeManager {
      ThemeManager(
        defaults: defaults,
        themesDirectory: themesDirectory,
        loadingService: loader,
        fileWatcher: NoOpThemeFileWatcher(),
        installBundledThemes: false,
        loadSavedThemeAsync: false
      )
    }

    func teardown() {
      try? FileManager.default.removeItem(at: themesDirectory)
      defaults.removePersistentDomain(forName: suiteName)
    }
  }

  private func loadedTheme(
    name: String,
    primary: String = "#112233",
    secondary: String = "#445566",
    tertiary: String = "#778899"
  ) throws -> LoadedYAMLTheme {
    let yaml = """
    name: "\(name)"
    version: "1.0"
    colors:
      brand:
        primary: "\(primary)"
        secondary: "\(secondary)"
        tertiary: "\(tertiary)"
    """
    let theme = try YAMLThemeParser().parse(data: Data(yaml.utf8))
    return LoadedYAMLTheme(
      theme: theme,
      palette: ThemePalette(primary: primary, secondary: secondary, tertiary: tertiary)
    )
  }
}
