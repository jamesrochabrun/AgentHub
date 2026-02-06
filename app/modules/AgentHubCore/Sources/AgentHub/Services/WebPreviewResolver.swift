//
//  WebPreviewResolver.swift
//  AgentHub
//
//  Stateless resolver that determines how to preview a project:
//  direct file:// loading for static HTML, or dev server for frameworks.
//

import Foundation

// MARK: - WebPreviewResolution

/// How a project should be previewed
enum WebPreviewResolution: Equatable {
  /// Load a file directly via file:// URL (instant, no server needed)
  case directFile(filePath: String, projectPath: String)
  /// Need a dev server (framework project requiring transpilation/bundling)
  case devServer(projectPath: String)
  /// No web content found
  case noContent(reason: String)
}

// MARK: - WebPreviewResolver

/// Determines the optimal preview strategy for a project path.
///
/// Resolution order (cheap checks first):
/// 1. Check if the project uses a framework requiring a dev server
/// 2. Check for index.html in project root (instant)
/// 3. Search git diffs (unstaged + staged only) for modified web-renderable files
/// 4. Search file tree for any .html file
enum WebPreviewResolver {

  static func resolve(projectPath: String) async -> WebPreviewResolution {
    // 1. Detect framework (fast, synchronous package.json check)
    let framework = await Task.detached {
      ProjectFramework.detect(at: projectPath)
    }.value

    // 2. Known framework requiring dev server → use dev server
    if framework.requiresDevServer {
      return .devServer(projectPath: projectPath)
    }

    // 3. Unknown framework with dev/start scripts → dev server
    if framework == .unknown {
      return .devServer(projectPath: projectPath)
    }

    // 4. Quick check: index.html in project root (instant, no git needed)
    let indexPath = "\(projectPath)/index.html"
    if FileManager.default.fileExists(atPath: indexPath) {
      return .directFile(filePath: indexPath, projectPath: projectPath)
    }

    // 5. Search unstaged + staged diffs for web-renderable files (skip branch — slow, less relevant)
    let diffFiles = await findWebRenderableFiles(at: projectPath)
    if let bestFile = pickBestFile(from: diffFiles) {
      return .directFile(filePath: bestFile.filePath, projectPath: projectPath)
    }

    // 6. Fallback: search for any .html file (breadth-first, prefer shallow)
    if let htmlFile = await findAnyHTMLFile(at: projectPath) {
      return .directFile(filePath: htmlFile, projectPath: projectPath)
    }

    return .noContent(reason: "No web-renderable files found in this project.")
  }

  // MARK: - Git Diff Search

  /// Collects web-renderable files from unstaged and staged diffs (skips branch for speed)
  static func findWebRenderableFiles(at projectPath: String) async -> [GitDiffFileEntry] {
    let service = GitDiffService()
    var allFiles: [String: GitDiffFileEntry] = [:]

    for mode in [DiffMode.unstaged, .staged] {
      do {
        let state = try await service.getChanges(at: projectPath, mode: mode)
        let webFiles = state.files.filter { $0.isWebRenderable }
        for file in webFiles {
          if let existing = allFiles[file.filePath] {
            let existingTotal = existing.additions + existing.deletions
            let newTotal = file.additions + file.deletions
            if newTotal > existingTotal {
              allFiles[file.filePath] = file
            }
          } else {
            allFiles[file.filePath] = file
          }
        }
      } catch {
        AppLogger.devServer.error("[WebPreviewResolver] \(mode.rawValue) failed: \(error.localizedDescription)")
      }
    }

    return Array(allFiles.values)
  }

  /// Picks the file with the most changes (additions + deletions)
  private static func pickBestFile(from files: [GitDiffFileEntry]) -> GitDiffFileEntry? {
    files.max { ($0.additions + $0.deletions) < ($1.additions + $1.deletions) }
  }

  // MARK: - File System Search

  /// Breadth-first search for any .html file, preferring shallower paths
  private static func findAnyHTMLFile(at projectPath: String) async -> String? {
    await Task.detached {
      let fm = FileManager.default
      let projectURL = URL(fileURLWithPath: projectPath)

      // Skip common directories that won't have user HTML
      let skipDirs: Set<String> = [
        "node_modules", ".git", ".svn", "build", "dist",
        ".next", ".nuxt", "__pycache__", ".cache"
      ]

      guard let enumerator = fm.enumerator(
        at: projectURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else {
        return nil
      }

      var candidates: [(path: String, depth: Int)] = []

      for case let fileURL as URL in enumerator {
        // Skip excluded directories
        let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir && skipDirs.contains(fileURL.lastPathComponent) {
          enumerator.skipDescendants()
          continue
        }

        if !isDir && fileURL.pathExtension.lowercased() == "html" {
          let relativePath = fileURL.path.replacingOccurrences(of: projectPath + "/", with: "")
          let depth = relativePath.components(separatedBy: "/").count
          candidates.append((fileURL.path, depth))
        }
      }

      // Return the shallowest file
      return candidates.min(by: { $0.depth < $1.depth })?.path
    }.value
  }
}
