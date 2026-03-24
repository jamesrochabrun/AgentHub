//
//  ProjectFileService.swift
//  AgentHub
//
//  Project-scoped file access used by the web preview inspector rail.
//

import Foundation

protocol ProjectFileServiceProtocol: Sendable {
  func readFile(at path: String, projectPath: String) async throws -> String
  func writeFile(at path: String, content: String, projectPath: String) async throws
  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String]
}

actor ProjectFileService: ProjectFileServiceProtocol {
  static let shared = ProjectFileService()

  private static let skippedDirectories: Set<String> = [
    ".git", ".svn", ".build", "DerivedData", "node_modules",
    ".next", ".nuxt", "dist", "build", "coverage", ".cache",
  ]

  private static let maxIndexedFileSize: UInt64 = 1_000_000

  func readFile(at path: String, projectPath: String) async throws -> String {
    try await FileIndexService.shared.readFile(at: path, projectPath: projectPath)
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    try await FileIndexService.shared.writeFile(at: path, content: content, projectPath: projectPath)
  }

  func listTextFiles(in projectPath: String, extensions allowedExtensions: Set<String>) async -> [String] {
    guard !allowedExtensions.isEmpty else { return [] }

    return await Task.detached(priority: .utility) {
      let rootURL = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath()
      let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]

      guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [.skipsHiddenFiles]
      ) else {
        return []
      }

      var filePaths: [String] = []

      while let fileURL = enumerator.nextObject() as? URL {
        let values = try? fileURL.resourceValues(forKeys: resourceKeys)
        let isDirectory = values?.isDirectory == true

        if isDirectory {
          if Self.skippedDirectories.contains(fileURL.lastPathComponent) {
            enumerator.skipDescendants()
          }
          continue
        }

        let ext = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { continue }

        if let fileSize = values?.fileSize, UInt64(fileSize) > Self.maxIndexedFileSize {
          continue
        }

        filePaths.append(fileURL.standardizedFileURL.resolvingSymlinksInPath().path)
      }

      return filePaths.sorted()
    }.value
  }
}
