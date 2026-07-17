import Foundation

/// The user's effective Ghostty background color per appearance, resolved
/// from their Ghostty configuration. Hex strings are normalized `#rrggbb`.
public struct GhosttyUserBackground: Equatable, Sendable {
  public let lightHex: String?
  public let darkHex: String?

  public init(lightHex: String?, darkHex: String?) {
    self.lightHex = lightHex
    self.darkHex = darkHex
  }

  public static let none = GhosttyUserBackground(lightHex: nil, darkHex: nil)

  /// The background to adopt for the given appearance, or nil to keep the
  /// app's own theme backdrop.
  ///
  /// A color is only adoptable when its luminance matches the appearance
  /// (dark color in dark mode, light color in light mode). The embedded
  /// terminal's text colors come from AgentHub's appearance overlay, so
  /// painting e.g. a dark user background behind light-mode (dark) text
  /// would be illegible.
  public func adoptableHex(isDark: Bool) -> String? {
    guard let hex = isDark ? darkHex : lightHex,
          let luminance = GhosttyUserThemeScanner.luminance(ofHex: hex) else {
      return nil
    }
    let colorIsDark = luminance < 0.5
    return colorIsDark == isDark ? hex : nil
  }
}

/// Resolves the user's Ghostty background colors by scanning the same config
/// files the embedded runtime loads (default Ghostty locations, then the
/// custom file from AgentHub Settings on top — see
/// `GhosttyLayeredConfigComposer`).
///
/// This is a deliberately narrow reader, not a full Ghostty config parser:
/// it understands line comments, `key = value` pairs, `config-file` includes
/// (BFS, matching `ghostty_config_load_recursive_files`), the `theme` key
/// (single name, `light:`/`dark:` pairs, or a file path), and hex `background`
/// values. Ghostty's rule "explicit config colors override the theme" is
/// honored. Anything it cannot understand resolves to "no adoption" rather
/// than a guess.
public enum GhosttyUserThemeScanner {

  public static func resolveBackground(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundledThemesDirectoryURL: URL? = nil,
    includeSystemThemeDirectories: Bool = true
  ) -> GhosttyUserBackground {
    var rootPaths = GhosttyConfigLocations.defaultConfigPaths(
      environment: environment,
      homeDirectoryURL: homeDirectoryURL
    )
    if let customPath = validatedCustomConfigPath(defaults: defaults, fileManager: fileManager),
       !rootPaths.contains(customPath) {
      rootPaths.append(customPath)
    }

    let scan = scanConfigFiles(at: rootPaths, fileManager: fileManager)

    if scan.sawUnparseableBackground {
      return .none
    }

    if let explicit = scan.backgroundHex {
      return GhosttyUserBackground(lightHex: explicit, darkHex: explicit)
    }

    guard let themeSpec = scan.themeSpec else { return .none }
    let themes = ThemePair(spec: themeSpec)
    let searchDirectories = GhosttyConfigLocations.themeSearchDirectories(
      environment: environment,
      homeDirectoryURL: homeDirectoryURL,
      bundledThemesDirectoryURL: bundledThemesDirectoryURL,
      includeSystemThemeDirectories: includeSystemThemeDirectories
    )

    func backgroundForTheme(_ name: String?) -> String? {
      guard let name else { return nil }
      guard let themeURL = locateTheme(
        named: name,
        searchDirectories: searchDirectories,
        fileManager: fileManager
      ) else { return nil }
      return scanConfigFiles(at: [themeURL.path], fileManager: fileManager).backgroundHex
    }

    return GhosttyUserBackground(
      lightHex: backgroundForTheme(themes.light),
      darkHex: backgroundForTheme(themes.dark)
    )
  }

  // MARK: - Config scanning

  struct ScanResult {
    var backgroundHex: String?
    var sawUnparseableBackground = false
    var themeSpec: String?
  }

  /// Scans config files with last-wins semantics. `config-file` includes are
  /// processed breadth-first after the file that declared them, matching
  /// libghostty's `ghostty_config_load_recursive_files`.
  static func scanConfigFiles(
    at rootPaths: [String],
    fileManager: FileManager,
    maximumFileCount: Int = 32
  ) -> ScanResult {
    var result = ScanResult()
    var queue = rootPaths
    var visited = Set<String>()

    while !queue.isEmpty, visited.count < maximumFileCount {
      let path = (queue.removeFirst() as NSString).expandingTildeInPath
      let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
      guard !visited.contains(canonical) else { continue }
      visited.insert(canonical)

      guard let contents = try? String(contentsOfFile: canonical, encoding: .utf8) else { continue }

      for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        guard let separator = line.firstIndex(of: "=") else { continue }

        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = unquote(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))

        switch key {
        case "background":
          if value.isEmpty {
            result.backgroundHex = nil
            result.sawUnparseableBackground = false
          } else if let hex = normalizedHex(value) {
            result.backgroundHex = hex
            result.sawUnparseableBackground = false
          } else {
            result.backgroundHex = nil
            result.sawUnparseableBackground = true
          }

        case "theme":
          result.themeSpec = value.isEmpty ? nil : value

        case "config-file":
          var includePath = value
          if includePath.hasPrefix("?") {
            includePath = String(includePath.dropFirst()).trimmingCharacters(in: .whitespaces)
          }
          guard !includePath.isEmpty else { continue }
          let expanded = (includePath as NSString).expandingTildeInPath
          if expanded.hasPrefix("/") {
            queue.append(expanded)
          } else {
            queue.append(
              URL(fileURLWithPath: canonical)
                .deletingLastPathComponent()
                .appendingPathComponent(expanded)
                .path
            )
          }

        default:
          break
        }
      }
    }

    return result
  }

  // MARK: - Theme resolution

  struct ThemePair {
    var light: String?
    var dark: String?

    /// Parses `theme = name` or `theme = light:Name A,dark:Name B`.
    init(spec: String) {
      for part in spec.split(separator: ",") {
        let entry = part.trimmingCharacters(in: .whitespaces)
        if entry.lowercased().hasPrefix("light:") {
          light = String(entry.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces)
        } else if entry.lowercased().hasPrefix("dark:") {
          dark = String(entry.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
        } else if light == nil, dark == nil {
          light = entry
          dark = entry
        }
      }
    }
  }

  static func locateTheme(
    named name: String,
    searchDirectories: [URL],
    fileManager: FileManager
  ) -> URL? {
    if name.contains("/") {
      let expanded = (name as NSString).expandingTildeInPath
      return fileManager.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
    }
    for directory in searchDirectories {
      let candidate = directory.appendingPathComponent(name, isDirectory: false)
      if fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  // MARK: - Colors

  /// Normalizes `#RRGGBB` / `RRGGBB` to lowercase `#rrggbb`; nil for
  /// anything else (named colors, short hex).
  static func normalizedHex(_ value: String) -> String? {
    var hex = value
    if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
    guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
    return "#" + hex.lowercased()
  }

  /// Perceived luminance in 0...1 for a normalized hex color.
  static func luminance(ofHex hex: String) -> Double? {
    guard let normalized = normalizedHex(hex) else { return nil }
    let digits = Array(normalized.dropFirst())
    func channel(_ offset: Int) -> Double {
      Double(Int(String(digits[offset...(offset + 1)]), radix: 16) ?? 0) / 255.0
    }
    return 0.299 * channel(0) + 0.587 * channel(2) + 0.114 * channel(4)
  }

  // MARK: - Helpers

  private static func validatedCustomConfigPath(
    defaults: UserDefaults,
    fileManager: FileManager
  ) -> String? {
    guard let rawPath = defaults.string(forKey: AgentHubDefaults.terminalGhosttyConfigPath) else {
      return nil
    }
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let expanded = (trimmed as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          fileManager.isReadableFile(atPath: expanded) else {
      return nil
    }
    return expanded
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    return String(value.dropFirst().dropLast())
  }
}
