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

    // 1. Check for .storybook/ config directory
    if fm.fileExists(atPath: "\(projectPath)/.storybook") {
      return true
    }

    // 2. Check package.json for storybook scripts or dependencies
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

  /// Default port for Storybook dev server.
  public static let defaultPort: Int = 6006

  /// Stdout patterns that indicate the Storybook server is ready.
  public static let readinessPatterns: [String] = ["Storybook", "localhost:", "started"]

  // MARK: - Private

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
