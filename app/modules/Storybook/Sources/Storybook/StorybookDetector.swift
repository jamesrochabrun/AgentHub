//
//  StorybookDetector.swift
//  Storybook
//
//  Detects whether a project has Storybook configured by checking for
//  .storybook/ directory, package.json scripts, or @storybook/ dependencies.
//

import Foundation

/// Detects Storybook presence in a project directory.
///
/// Detection checks (in order):
/// 1. `.storybook/` config directory at project root
/// 2. `"storybook"` script key in `package.json` scripts
/// 3. Any `@storybook/*` package in `devDependencies`
///
/// ```swift
/// if StorybookDetector.hasStorybook(at: "/path/to/project") {
///   // Show Storybook UI, start server, etc.
/// }
/// ```
public enum StorybookDetector {

  /// Whether the project at the given path has Storybook configured.
  public static func hasStorybook(at projectPath: String) -> Bool {
    let fm = FileManager.default

    if fm.fileExists(atPath: "\(projectPath)/.storybook") {
      return true
    }

    guard let packageJSON = readPackageJSON(at: projectPath) else {
      return false
    }

    if let scripts = packageJSON["scripts"] as? [String: String],
       scripts["storybook"] != nil {
      return true
    }

    if let devDeps = packageJSON["devDependencies"] as? [String: Any],
       devDeps.keys.contains(where: { $0.hasPrefix("@storybook/") }) {
      return true
    }

    return false
  }

  /// Returns the Storybook start script name from package.json, if found.
  /// Checks for `"storybook"` first, then `"storybook:dev"`.
  public static func storybookScript(at projectPath: String) -> String? {
    guard let packageJSON = readPackageJSON(at: projectPath),
          let scripts = packageJSON["scripts"] as? [String: String] else {
      return nil
    }
    if scripts["storybook"] != nil { return "storybook" }
    if scripts["storybook:dev"] != nil { return "storybook:dev" }
    return nil
  }

  /// Returns the port pinned by the storybook script's args, if present.
  /// Recognizes `-p 6006`, `-p=6006`, `--port 6006`, `--port=6006`.
  /// When non-nil, the caller must NOT append its own `-p` argument — npm
  /// would just append it *after* the script's args, and storybook honors
  /// the first occurrence, so the user-visible port and the manager-tracked
  /// port would diverge.
  public static func storybookScriptPort(at projectPath: String) -> Int? {
    guard let packageJSON = readPackageJSON(at: projectPath),
          let scripts = packageJSON["scripts"] as? [String: String] else {
      return nil
    }
    guard let script = scripts["storybook"] ?? scripts["storybook:dev"] else { return nil }
    return parsePort(from: script)
  }

  /// Default port for Storybook dev server.
  public static let defaultPort: Int = 6006

  /// Stdout patterns that indicate the Storybook server is ready.
  /// Limited to URL-bearing lines so we don't match npm's pre-launch header
  /// (e.g. `> storybook-demo@0.0.0 storybook`) before the port is bound.
  public static let readinessPatterns: [String] = ["Local:", "localhost:"]

  // MARK: - Private

  private static func parsePort(from script: String) -> Int? {
    // Try `-p 6006`, `-p=6006`, `--port 6006`, `--port=6006`
    let patterns = [
      #"(?<![\w-])-p[\s=](\d+)"#,
      #"--port[\s=](\d+)"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(script.startIndex..., in: script)
      if let match = regex.firstMatch(in: script, range: range),
         match.numberOfRanges > 1,
         let portRange = Range(match.range(at: 1), in: script),
         let port = Int(script[portRange]) {
        return port
      }
    }
    return nil
  }

  private static func readPackageJSON(at projectPath: String) -> [String: Any]? {
    let fm = FileManager.default
    let path = "\(projectPath)/package.json"
    guard fm.fileExists(atPath: path),
          let data = fm.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return json
  }
}
