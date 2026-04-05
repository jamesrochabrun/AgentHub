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
  /// The agent advertised a localhost URL that isn't reachable (or died mid-session).
  /// Present an actionable chooser instead of a blank WKWebView.
  ///
  /// Marked `indirect` because `WebPreviewLaunchOptions` holds a nested
  /// `WebPreviewResolution` for its static fallback.
  indirect case launchOptions(WebPreviewLaunchOptions, unreachableURL: URL?)
  /// No web content found
  case noContent(reason: String)
}

// MARK: - WebPreviewResolver

/// Determines the optimal preview strategy for a project path.
///
/// Resolution order (cheap checks first):
/// 1. Check if the project uses a framework requiring a dev server
/// 2. Fall back to static HTML (root index.html first, then discovered HTML)
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

    return await resolveStaticPreview(projectPath: projectPath)
  }

  /// Builds a `.launchOptions` resolution describing the actionable choices
  /// presented when an agent-advertised localhost URL cannot be reached.
  ///
  /// - Parameters:
  ///   - projectPath: Project directory used to compute the static fallback.
  ///   - unreachableURL: The URL that failed the reachability probe, shown in
  ///     the status message. `nil` when presented for reasons other than an
  ///     unreachable probe (e.g. a late disconnect).
  ///   - canAskAgent: Whether the "Ask Agent" affordance should be offered.
  ///     Defaults to `true` because this resolution is only produced in
  ///     contexts where a live session is attached.
  static func resolveLaunchOptions(
    projectPath: String,
    unreachableURL: URL?,
    canAskAgent: Bool = true
  ) async -> WebPreviewResolution {
    let staticResolution = await resolveStaticPreview(projectPath: projectPath)
    let options = WebPreviewLaunchOptions(
      staticPreviewResolution: staticResolution,
      canAskAgent: canAskAgent
    )
    return .launchOptions(options, unreachableURL: unreachableURL)
  }

  /// Resolves the best static preview candidate without considering framework/dev-server preference.
  /// Used as a fallback when an external localhost preview cannot be loaded.
  static func resolveStaticPreview(projectPath: String) async -> WebPreviewResolution {
    // 1. Quick check: index.html in project root (instant, no git needed)
    if let indexPath = findRootIndexHTML(at: projectPath) {
      return .directFile(filePath: indexPath, projectPath: projectPath)
    }

    // 2. Search unstaged + staged diffs for web-renderable files (skip branch — slow, less relevant)
    let diffFiles = await findWebRenderableFiles(at: projectPath)
    if let bestFile = pickBestFile(from: diffFiles) {
      return .directFile(filePath: bestFile.filePath, projectPath: projectPath)
    }

    // 3. Fallback: search for any .html file (breadth-first, prefer shallow)
    if let htmlFile = await findAnyHTMLFile(at: projectPath) {
      return .directFile(filePath: htmlFile, projectPath: projectPath)
    }

    return .noContent(reason: "No web-renderable files found in this project.")
  }

  /// Quick synchronous check for common HTML entry points.
  /// Uses only fileExists (stat syscall) — no directory listing — so it's safe to call from view bodies.
  static func hasAnyHTMLFile(at projectPath: String) -> Bool {
    let fm = FileManager.default
    let candidates = [
      "\(projectPath)/index.html",
      "\(projectPath)/public/index.html",
      "\(projectPath)/static/index.html",
      "\(projectPath)/src/index.html",
      "\(projectPath)/dist/index.html",
      "\(projectPath)/build/index.html",
      "\(projectPath)/www/index.html",
    ]
    return candidates.contains(where: { fm.fileExists(atPath: $0) })
  }

  private static func findRootIndexHTML(at projectPath: String) -> String? {
    let indexPath = "\(projectPath)/index.html"
    if FileManager.default.fileExists(atPath: indexPath) {
      return indexPath
    }
    return nil
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

      while let fileURL = enumerator.nextObject() as? URL {
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
