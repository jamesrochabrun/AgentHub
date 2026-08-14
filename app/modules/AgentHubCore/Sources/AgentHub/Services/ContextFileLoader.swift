//
//  ContextFileLoader.swift
//  AgentHub
//
//  Resolves a context selection's project-relative paths into file contents,
//  off the main actor, with a bounded number of contents held in flight.
//  Reads go through FileIndexService so path validation (stay inside the
//  project root) and UTF-8 checking are enforced in one place.
//

import Foundation

public struct ContextLoadedFile: Equatable, Sendable {
  public let relativePath: String
  public let content: String
  public let metrics: TextFileMetrics

  public init(relativePath: String, content: String, metrics: TextFileMetrics) {
    self.relativePath = relativePath
    self.content = content
    self.metrics = metrics
  }

  public init(relativePath: String, content: String) {
    self.init(relativePath: relativePath, content: content, metrics: .metrics(for: content))
  }
}

public struct ContextFileLoadResult: Sendable {
  /// Successfully read files, sorted by relative path.
  public let loaded: [ContextLoadedFile]
  /// Relative paths that could not be read (missing, unreadable, non-UTF-8,
  /// or outside the project root), sorted.
  public let missing: [String]
  /// Paths that exist but cannot be inlined (binary formats such as PDFs and
  /// images, or files over the inline size cap). Included in the context as
  /// references the agent reads with its own tools.
  public let attachments: [String]

  public init(loaded: [ContextLoadedFile], missing: [String], attachments: [String] = []) {
    self.loaded = loaded
    self.missing = missing
    self.attachments = attachments
  }
}

/// What a selected path resolves to (project-relative or external).
public enum ContextFileStatus: Equatable, Sendable {
  /// UTF-8 text small enough to inline.
  case text(TextFileMetrics)
  /// Exists but is referenced by path instead of inlined (binary or too large).
  case attachment
  case missing
}

public protocol ContextFileLoading: Sendable {
  func loadFiles(relativePaths: [String], projectPath: String) async -> ContextFileLoadResult
  /// Metrics only (no contents retained) — cheap enough to refresh a token
  /// column on every selection toggle. Unreadable paths are omitted.
  func fileMetrics(relativePaths: [String], projectPath: String) async -> [String: TextFileMetrics]
  /// Classifies project-relative paths without retaining contents: existing
  /// text is `.text`, binary or oversized files are `.attachment` (they exist —
  /// the agent reads them itself), unresolvable paths are `.missing`.
  func projectFileStatuses(relativePaths: [String], projectPath: String) async -> [String: ContextFileStatus]
  /// Loads files from absolute paths outside the project root (other repos,
  /// documents, books). Binary or oversized files land in `attachments`.
  func loadExternalFiles(absolutePaths: [String]) async -> ContextFileLoadResult
  /// Classifies external paths without retaining contents.
  func externalFileStatuses(absolutePaths: [String]) async -> [String: ContextFileStatus]
}

public actor ContextFileLoader: ContextFileLoading {

  private struct MetricsCacheEntry {
    let fileSize: Int
    let modificationDate: Date
    let metrics: TextFileMetrics
  }

  private let fileIndexService: FileIndexService
  private let maxConcurrentReads: Int
  private var metricsCache: [String: MetricsCacheEntry] = [:]

  public init(fileIndexService: FileIndexService = .shared, maxConcurrentReads: Int = 8) {
    self.fileIndexService = fileIndexService
    self.maxConcurrentReads = max(1, maxConcurrentReads)
  }

  public func loadFiles(relativePaths: [String], projectPath: String) async -> ContextFileLoadResult {
    let uniquePaths = orderedUnique(relativePaths)
    var loaded: [ContextLoadedFile] = []
    var missing: [String] = []
    var attachments: [String] = []

    await withTaskGroup(of: (String, ProjectFileRead).self) { group in
      var iterator = uniquePaths.makeIterator()
      var inFlight = 0

      func addNext() {
        guard let relativePath = iterator.next() else { return }
        inFlight += 1
        let absolutePath = Self.absolutePath(for: relativePath, projectPath: projectPath)
        group.addTask { [fileIndexService] in
          (relativePath, await Self.readProjectFile(
            atPath: absolutePath, projectPath: projectPath, fileIndexService: fileIndexService))
        }
      }

      for _ in 0..<maxConcurrentReads { addNext() }

      for await (relativePath, read) in group {
        inFlight -= 1
        switch read {
        case .text(let file):
          loaded.append(ContextLoadedFile(
            relativePath: relativePath,
            content: file.content,
            metrics: file.metrics
          ))
          cacheMetrics(file.metrics, relativePath: relativePath, projectPath: projectPath)
        case .attachment:
          attachments.append(relativePath)
        case .missing:
          missing.append(relativePath)
        }
        addNext()
      }
    }

    return ContextFileLoadResult(
      loaded: loaded.sorted { $0.relativePath < $1.relativePath },
      missing: missing.sorted(),
      attachments: attachments.sorted()
    )
  }

  public func projectFileStatuses(
    relativePaths: [String], projectPath: String
  ) async -> [String: ContextFileStatus] {
    var statuses: [String: ContextFileStatus] = [:]
    for relativePath in orderedUnique(relativePaths) {
      let absolutePath = Self.absolutePath(for: relativePath, projectPath: projectPath)
      if let entry = cachedMetricsEntry(atAbsolutePath: absolutePath) {
        statuses[relativePath] = .text(entry.metrics)
        continue
      }
      switch await Self.readProjectFile(
        atPath: absolutePath, projectPath: projectPath, fileIndexService: fileIndexService
      ) {
      case .text(let file):
        cacheMetrics(file.metrics, relativePath: relativePath, projectPath: projectPath)
        statuses[relativePath] = .text(file.metrics)
      case .attachment:
        statuses[relativePath] = .attachment
      case .missing:
        statuses[relativePath] = .missing
      }
    }
    return statuses
  }

  public func fileMetrics(relativePaths: [String], projectPath: String) async -> [String: TextFileMetrics] {
    var result: [String: TextFileMetrics] = [:]
    for relativePath in orderedUnique(relativePaths) {
      let absolutePath = Self.absolutePath(for: relativePath, projectPath: projectPath)
      guard let attributes = Self.fileAttributes(atPath: absolutePath) else { continue }

      if let entry = metricsCache[absolutePath],
        entry.fileSize == attributes.fileSize,
        entry.modificationDate == attributes.modificationDate {
        result[relativePath] = entry.metrics
        continue
      }

      guard let file = try? await fileIndexService.readTextFile(at: absolutePath, projectPath: projectPath) else {
        continue
      }
      metricsCache[absolutePath] = MetricsCacheEntry(
        fileSize: attributes.fileSize,
        modificationDate: attributes.modificationDate,
        metrics: file.metrics
      )
      result[relativePath] = file.metrics
    }
    return result
  }

  // MARK: - Private

  private enum ProjectFileRead: Sendable {
    case text(ProjectTextFile)
    case attachment
    case missing
  }

  /// Classifies and (when inlinable) reads one project file. Oversized files
  /// are never read; binary files surface as the UTF-8 failure the read throws.
  private static func readProjectFile(
    atPath absolutePath: String,
    projectPath: String,
    fileIndexService: FileIndexService
  ) async -> ProjectFileRead {
    if let attributes = fileAttributes(atPath: absolutePath),
      attributes.fileSize > maxProjectInlineBytes {
      // Attachment paths are handed to the agent unread, so confinement must
      // be checked here; inlined reads get the authoritative (symlink-
      // resolving) check inside readTextFile.
      return isWithinProject(absolutePath: absolutePath, projectPath: projectPath)
        ? .attachment : .missing
    }
    do {
      let file = try await fileIndexService.readTextFile(at: absolutePath, projectPath: projectPath)
      return .text(file)
    } catch let error as CocoaError where error.code == .fileReadCorruptFile {
      // Exists inside the root but is not UTF-8 text (PDF, image, archive, …).
      return .attachment
    } catch {
      return .missing
    }
  }

  private static func isWithinProject(absolutePath: String, projectPath: String) -> Bool {
    let root = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let candidate = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
    return candidate == root || candidate.hasPrefix(root + "/")
  }

  private func cachedMetricsEntry(atAbsolutePath absolutePath: String) -> MetricsCacheEntry? {
    guard let attributes = Self.fileAttributes(atPath: absolutePath),
      let entry = metricsCache[absolutePath],
      entry.fileSize == attributes.fileSize,
      entry.modificationDate == attributes.modificationDate
    else { return nil }
    return entry
  }

  private func cacheMetrics(_ metrics: TextFileMetrics, relativePath: String, projectPath: String) {
    let absolutePath = Self.absolutePath(for: relativePath, projectPath: projectPath)
    guard let attributes = Self.fileAttributes(atPath: absolutePath) else { return }
    metricsCache[absolutePath] = MetricsCacheEntry(
      fileSize: attributes.fileSize,
      modificationDate: attributes.modificationDate,
      metrics: metrics
    )
  }

  private func orderedUnique(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  private static func absolutePath(for relativePath: String, projectPath: String) -> String {
    (projectPath as NSString).appendingPathComponent(relativePath)
  }

  private static func fileAttributes(atPath path: String) -> (fileSize: Int, modificationDate: Date)? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attributes[.size] as? Int,
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return (size, modified)
  }

  // MARK: - External files

  /// External text files above this size are referenced as attachments instead
  /// of inlined — a book-sized text would blow past any context window anyway.
  public static let maxExternalInlineBytes = 10 * 1024 * 1024
  /// Project files share the same inline cap: oversized files exist and are
  /// part of the context, so they are referenced, never reported missing.
  public static let maxProjectInlineBytes = maxExternalInlineBytes

  public func loadExternalFiles(absolutePaths: [String]) async -> ContextFileLoadResult {
    var loaded: [ContextLoadedFile] = []
    var missing: [String] = []
    var attachments: [String] = []

    for path in orderedUnique(absolutePaths) {
      switch Self.readExternalFile(atPath: path) {
      case .text(let content, let metrics):
        loaded.append(ContextLoadedFile(relativePath: path, content: content, metrics: metrics))
      case .attachment:
        attachments.append(path)
      case .missing:
        missing.append(path)
      }
    }

    return ContextFileLoadResult(
      loaded: loaded.sorted { $0.relativePath < $1.relativePath },
      missing: missing.sorted(),
      attachments: attachments.sorted()
    )
  }

  public func externalFileStatuses(absolutePaths: [String]) async -> [String: ContextFileStatus] {
    var statuses: [String: ContextFileStatus] = [:]
    for path in orderedUnique(absolutePaths) {
      switch Self.readExternalFile(atPath: path) {
      case .text(_, let metrics): statuses[path] = .text(metrics)
      case .attachment: statuses[path] = .attachment
      case .missing: statuses[path] = .missing
      }
    }
    return statuses
  }

  private enum ExternalRead {
    case text(String, TextFileMetrics)
    case attachment
    case missing
  }

  private static func readExternalFile(atPath path: String) -> ExternalRead {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return .missing }

    guard let attributes = fileAttributes(atPath: path) else { return .missing }
    guard attributes.fileSize <= maxExternalInlineBytes else { return .attachment }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
      let content = String(data: data, encoding: .utf8)
    else {
      // Exists but is not UTF-8 text (PDF, image, docx, …) — reference it.
      return .attachment
    }
    return .text(content, TextFileMetrics.metrics(forUTF8Data: data))
  }

  /// Filters user-picked URLs down to existing regular files (external
  /// selection is files-only; the picker multi-selects so many files can be
  /// added in one pass).
  public static func regularFilePaths(from urls: [URL]) -> [String] {
    var paths: [String] = []
    var seen = Set<String>()
    for url in urls {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        seen.insert(url.path).inserted
      else { continue }
      paths.append(url.path)
    }
    return paths
  }
}
