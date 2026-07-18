import Foundation

/// Canonical filesystem locations of the user's Ghostty configuration on
/// macOS. Shared by the embedded-terminal config layering (Ghostty module)
/// and the user-theme background resolution (theme system), so both agree on
/// what "the user's Ghostty config" means.
public enum GhosttyConfigLocations {

  /// Ghostty's default config file locations, in Ghostty's own load order
  /// (XDG first, Application Support last so it takes precedence).
  public static func defaultConfigPaths(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [String] {
    [
      xdgConfigBaseURL(environment: environment, homeDirectoryURL: homeDirectoryURL)
        .appendingPathComponent("ghostty", isDirectory: true)
        .appendingPathComponent("config", isDirectory: false)
        .path,
      applicationSupportGhosttyURL(homeDirectoryURL: homeDirectoryURL)
        .appendingPathComponent("config", isDirectory: false)
        .path,
    ]
  }

  /// Directories searched for a named `theme`, in precedence order (first
  /// match wins). Mirrors Ghostty: user theme dirs first, then the bundled
  /// resource themes (`share/ghostty/themes`) supplied by the caller.
  public static func themeSearchDirectories(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundledThemesDirectoryURL: URL? = nil,
    includeSystemThemeDirectories: Bool = true
  ) -> [URL] {
    var directories = [
      xdgConfigBaseURL(environment: environment, homeDirectoryURL: homeDirectoryURL)
        .appendingPathComponent("ghostty", isDirectory: true)
        .appendingPathComponent("themes", isDirectory: true),
      applicationSupportGhosttyURL(homeDirectoryURL: homeDirectoryURL)
        .appendingPathComponent("themes", isDirectory: true),
    ]
    if let bundledThemesDirectoryURL {
      directories.append(bundledThemesDirectoryURL)
    }
    if includeSystemThemeDirectories {
      // GHOSTTY_RESOURCES_DIR is exported by the embedded runtime once it
      // has configured GhosttySwift's bundled resources; the Ghostty.app
      // path covers named themes before the runtime exists.
      if let resourcesDir = environment["GHOSTTY_RESOURCES_DIR"], !resourcesDir.isEmpty {
        directories.append(
          URL(fileURLWithPath: resourcesDir, isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        )
      }
      directories.append(
        URL(
          fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
          isDirectory: true
        )
      )
    }
    return directories
  }

  private static func xdgConfigBaseURL(
    environment: [String: String],
    homeDirectoryURL: URL
  ) -> URL {
    if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
      return URL(fileURLWithPath: (xdgConfigHome as NSString).expandingTildeInPath, isDirectory: true)
    }
    return homeDirectoryURL.appendingPathComponent(".config", isDirectory: true)
  }

  private static func applicationSupportGhosttyURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
  }
}
