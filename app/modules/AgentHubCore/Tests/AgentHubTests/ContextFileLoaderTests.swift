import Foundation
import Testing

@testable import AgentHubCore

@Suite("Context file loader")
struct ContextFileLoaderTests {

  private func withProject(_ body: (URL, ContextFileLoader) async throws -> Void) async throws {
    let project = FileManager.default.temporaryDirectory
      .appendingPathComponent("context-loader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let loader = ContextFileLoader(fileIndexService: FileIndexService(), maxConcurrentReads: 2)
    try await body(project, loader)
  }

  private func write(_ relativePath: String, _ content: String, in project: URL) throws {
    let url = project.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  @Test("Loads readable files and reports missing ones, both sorted")
  func loadsSubsetAndReportsMissing() async throws {
    try await withProject { project, loader in
      try write("src/b.swift", "let b = 2", in: project)
      try write("src/a.swift", "line1\nline2", in: project)

      let result = await loader.loadFiles(
        relativePaths: ["src/b.swift", "missing/z.swift", "src/a.swift", "missing/a.swift"],
        projectPath: project.path
      )

      #expect(result.loaded.map(\.relativePath) == ["src/a.swift", "src/b.swift"])
      #expect(result.loaded.first?.content == "line1\nline2")
      #expect(result.loaded.first?.metrics.lineCount == 2)
      #expect(result.missing == ["missing/a.swift", "missing/z.swift"])
    }
  }

  @Test("Duplicate paths are loaded once")
  func deduplicatesPaths() async throws {
    try await withProject { project, loader in
      try write("one.swift", "let one = 1", in: project)

      let result = await loader.loadFiles(
        relativePaths: ["one.swift", "one.swift", "one.swift"],
        projectPath: project.path
      )

      #expect(result.loaded.count == 1)
      #expect(result.missing.isEmpty)
    }
  }

  @Test("Paths escaping the project root are reported missing, not read")
  func rejectsPathTraversal() async throws {
    try await withProject { project, loader in
      let outside = project.deletingLastPathComponent()
        .appendingPathComponent("outside-\(UUID().uuidString).txt")
      try "secret".write(to: outside, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: outside) }

      let result = await loader.loadFiles(
        relativePaths: ["../\(outside.lastPathComponent)"],
        projectPath: project.path
      )

      #expect(result.loaded.isEmpty)
      #expect(result.missing.count == 1)
    }
  }

  @Test("Metrics are returned per path and omit unreadable files")
  func metricsPerPath() async throws {
    try await withProject { project, loader in
      try write("a.swift", "12345678", in: project)

      let metrics = await loader.fileMetrics(
        relativePaths: ["a.swift", "gone.swift"],
        projectPath: project.path
      )

      #expect(metrics.count == 1)
      #expect(metrics["a.swift"]?.byteCount == 8)
    }
  }

  @Test("Metrics cache invalidates when the file changes")
  func metricsCacheInvalidation() async throws {
    try await withProject { project, loader in
      try write("a.swift", "short", in: project)
      let first = await loader.fileMetrics(relativePaths: ["a.swift"], projectPath: project.path)
      #expect(first["a.swift"]?.byteCount == 5)

      try write("a.swift", "much longer content", in: project)
      let second = await loader.fileMetrics(relativePaths: ["a.swift"], projectPath: project.path)
      #expect(second["a.swift"]?.byteCount == 19)
    }
  }

  @Test("Many files load with a small concurrency bound")
  func boundedConcurrencyLoadsAll() async throws {
    try await withProject { project, loader in
      for index in 0..<20 {
        try write("file-\(index).swift", "let value = \(index)", in: project)
      }

      let result = await loader.loadFiles(
        relativePaths: (0..<20).map { "file-\($0).swift" },
        projectPath: project.path
      )

      #expect(result.loaded.count == 20)
      #expect(result.missing.isEmpty)
    }
  }

  @Test("Binary project files are attachments, not missing")
  func binaryProjectFilesAreAttachments() async throws {
    try await withProject { project, loader in
      let binaryURL = project.appendingPathComponent("docs/spec.pdf")
      try FileManager.default.createDirectory(
        at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE, 0x00, 0x01]).write(to: binaryURL)
      try write("readme.md", "text", in: project)

      let result = await loader.loadFiles(
        relativePaths: ["docs/spec.pdf", "readme.md", "gone.md"],
        projectPath: project.path
      )

      #expect(result.loaded.map(\.relativePath) == ["readme.md"])
      #expect(result.attachments == ["docs/spec.pdf"])
      #expect(result.missing == ["gone.md"])

      let statuses = await loader.projectFileStatuses(
        relativePaths: ["docs/spec.pdf", "readme.md", "gone.md"], projectPath: project.path)
      #expect(statuses["docs/spec.pdf"] == .attachment)
      #expect(statuses["gone.md"] == .missing)
      if case .text(let metrics)? = statuses["readme.md"] {
        #expect(metrics.byteCount == 4)
      } else {
        Issue.record("expected text status")
      }
    }
  }

  @Test("Oversized project files are attachments and are never inlined")
  func oversizedProjectFilesAreAttachments() async throws {
    try await withProject { project, loader in
      let bigURL = project.appendingPathComponent("dump.txt")
      try Data(count: ContextFileLoader.maxProjectInlineBytes + 1).write(to: bigURL)

      let result = await loader.loadFiles(relativePaths: ["dump.txt"], projectPath: project.path)
      #expect(result.loaded.isEmpty)
      #expect(result.attachments == ["dump.txt"])
      #expect(result.missing.isEmpty)

      let statuses = await loader.projectFileStatuses(
        relativePaths: ["dump.txt"], projectPath: project.path)
      #expect(statuses["dump.txt"] == .attachment)
    }
  }

  @Test("Oversized files outside the project root stay missing, not attachments")
  func oversizedTraversalStaysMissing() async throws {
    try await withProject { project, loader in
      let outside = project.deletingLastPathComponent()
        .appendingPathComponent("big-outside-\(UUID().uuidString).bin")
      try Data(count: ContextFileLoader.maxProjectInlineBytes + 1).write(to: outside)
      defer { try? FileManager.default.removeItem(at: outside) }

      let result = await loader.loadFiles(
        relativePaths: ["../\(outside.lastPathComponent)"],
        projectPath: project.path
      )

      #expect(result.loaded.isEmpty)
      #expect(result.attachments.isEmpty)
      #expect(result.missing.count == 1)
    }
  }

  // MARK: - External files

  @Test("External files load by absolute path; binary files become attachments")
  func externalFilesLoadAndClassify() async throws {
    try await withProject { project, loader in
      let outside = project.deletingLastPathComponent()
        .appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: outside) }

      let textURL = outside.appendingPathComponent("notes.md")
      try "external notes".write(to: textURL, atomically: true, encoding: .utf8)
      let binaryURL = outside.appendingPathComponent("book.pdf")
      try Data([0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE, 0x00, 0x01]).write(to: binaryURL)

      let result = await loader.loadExternalFiles(absolutePaths: [
        textURL.path, binaryURL.path, outside.appendingPathComponent("gone.txt").path,
      ])

      #expect(result.loaded.map(\.relativePath) == [textURL.path])
      #expect(result.loaded.first?.content == "external notes")
      #expect(result.attachments == [binaryURL.path])
      #expect(result.missing.count == 1)

      let statuses = await loader.externalFileStatuses(absolutePaths: [
        textURL.path, binaryURL.path,
      ])
      #expect(statuses[binaryURL.path] == .attachment)
      if case .text(let metrics)? = statuses[textURL.path] {
        #expect(metrics.byteCount == 14)
      } else {
        Issue.record("expected text status")
      }
    }
  }

  @Test("Picker URLs filter to existing regular files — directories are ignored")
  func regularFilePathsFiltering() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pick-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("notes.md")
    try "a".write(to: file, atomically: true, encoding: .utf8)

    let paths = ContextFileLoader.regularFilePaths(from: [
      file,
      root,  // directory — ignored
      root.appendingPathComponent("gone.md"),  // missing — ignored
      file,  // duplicate — deduped
    ])

    #expect(paths == [file.path])
  }
}
