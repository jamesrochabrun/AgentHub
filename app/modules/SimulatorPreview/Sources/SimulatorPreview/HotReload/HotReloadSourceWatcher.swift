import CoreServices
import Foundation

// MARK: - Classification

/// Decides whether a file-system event on a project source is a hot-swappable
/// edit or a structural change that needs a rebuild. Pure logic — the watcher
/// feeds it paths plus an existence probe, tests feed it fixtures.
///
/// "Structural" is decided by file existence against a snapshot of known
/// sources, not by FSEvents flags: editors save via atomic rename, so a
/// renamed flag on an existing file is still just an edit.
public struct HotReloadSourceEventClassifier: Sendable {

  /// Path fragments that never count as project sources.
  private static let excludedFragments = [
    "/.git/", "/DerivedData/", "/.build/", "/.swiftpm/", "/Pods/",
  ]

  private var knownSources: Set<String>

  public init(knownSources: Set<String>) {
    self.knownSources = knownSources
  }

  /// Snapshot the watchable Swift sources under a root (used to seed the
  /// known set when the watcher starts).
  public static func swiftSources(
    under root: String,
    fileManager: FileManager = .default
  ) -> Set<String> {
    var sources = Set<String>()
    let rootURL = URL(fileURLWithPath: root)
    let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    while let url = enumerator?.nextObject() as? URL {
      let path = url.path
      if Self.isExcluded(path: path) {
        if url.hasDirectoryPath { enumerator?.skipDescendants() }
        continue
      }
      if path.hasSuffix(".swift") { sources.insert(path) }
    }
    return sources
  }

  /// Classifies one changed path, updating the known-sources snapshot.
  /// Returns nil for non-Swift files and excluded directories.
  public mutating func classify(
    path: String,
    fileExists: (String) -> Bool
  ) -> HotReloadSourceChange? {
    guard path.hasSuffix(".swift"), !Self.isExcluded(path: path) else {
      return nil
    }

    let exists = fileExists(path)
    let wasKnown = knownSources.contains(path)

    switch (exists, wasKnown) {
    case (false, true):
      knownSources.remove(path)
      return .structural(path: path, kind: .deleted)
    case (false, false):
      // Transient file (editor swap file already gone) — not actionable.
      return nil
    case (true, false):
      knownSources.insert(path)
      return .structural(path: path, kind: .created)
    case (true, true):
      return .injectable(path: path)
    }
  }

  private static func isExcluded(path: String) -> Bool {
    excludedFragments.contains { path.contains($0) }
  }
}

// MARK: - Watcher

/// Watches a project's Swift sources host-side and reports classified
/// changes. This is the signal for the pill's "Reloading…" onset and for the
/// structural-change → rebuild fallback; the injection engine inside the app
/// has its own watcher and does the actual recompiling.
public protocol HotReloadSourceWatching: AnyObject {
  /// Starts watching. `onChange` is delivered on the main queue.
  func start(
    projectPath: String,
    onChange: @escaping ([HotReloadSourceChange]) -> Void
  )
  func stop()
}

/// FSEvents-backed implementation. FSEvents (not kqueue) because source
/// trees need recursive watching with rename semantics; this mirrors the
/// engine-side watcher so the two stay in agreement about what changed.
public final class HotReloadSourceWatcher: HotReloadSourceWatching {

  private var stream: FSEventStreamRef?
  private var classifier = HotReloadSourceEventClassifier(knownSources: [])
  private var onChange: (([HotReloadSourceChange]) -> Void)?

  public init() {}

  deinit {
    stop()
  }

  public func start(
    projectPath: String,
    onChange: @escaping ([HotReloadSourceChange]) -> Void
  ) {
    stop()
    classifier = HotReloadSourceEventClassifier(
      knownSources: HotReloadSourceEventClassifier.swiftSources(under: projectPath)
    )
    self.onChange = onChange

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<HotReloadSourceWatcher>.fromOpaque(info)
        .takeUnretainedValue()
      guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String]
      else { return }
      watcher.handle(paths: Array(paths.prefix(eventCount)))
    }

    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      &context,
      [projectPath] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.15,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
      )
    ) else { return }

    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
  }

  public func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    onChange = nil
  }

  private func handle(paths: [String]) {
    var changes: [HotReloadSourceChange] = []
    for path in Set(paths) {
      if let change = classifier.classify(
        path: path,
        fileExists: { FileManager.default.fileExists(atPath: $0) }
      ) {
        changes.append(change)
      }
    }
    guard !changes.isEmpty else { return }
    onChange?(changes)
  }
}
