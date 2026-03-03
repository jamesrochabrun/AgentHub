//
//  XcodeProjectDetector.swift
//  AgentHub
//
//  Fast sync filesystem check for detecting Xcode projects.
//

import Foundation

enum XcodeProjectDetector {
  static func isXcodeProject(at path: String) -> Bool {
    // Check the root directory
    if containsXcodeProject(at: path) { return true }
    // Check one level of subdirectories (e.g. project root has app/Foo.xcodeproj)
    guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
    return subdirs.contains { sub in
      var isDir: ObjCBool = false
      let full = (path as NSString).appendingPathComponent(sub)
      FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
      return isDir.boolValue && containsXcodeProject(at: full)
    }
  }

  /// Parses project.pbxproj to determine which platforms the project supports.
  /// Falls back to [.iOS] when detection is ambiguous or the project file is not found.
  static func supportedPlatforms(at path: String) -> Set<XcodePlatform> {
    guard let xcodeprojPath = findXcodeproj(at: path) else { return [.iOS] }
    let pbxprojPath = (xcodeprojPath as NSString).appendingPathComponent("project.pbxproj")
    guard let content = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else { return [.iOS] }

    var platforms: Set<XcodePlatform> = []
    if content.contains("SDKROOT = macosx") { platforms.insert(.macOS) }
    if content.contains("SDKROOT = iphoneos") { platforms.insert(.iOS) }
    // Multi-platform projects (SDKROOT = auto) list all platforms under SUPPORTED_PLATFORMS.
    // Scope to lines that actually assign the key to avoid false positives from SDK-keyed
    // settings like EXCLUDED_ARCHS[sdk=iphoneos*] that appear in macOS-only projects.
    let supportedPlatformLines = content
      .components(separatedBy: "\n")
      .filter { $0.contains("SUPPORTED_PLATFORMS") && $0.contains("=") }
    if !supportedPlatformLines.isEmpty {
      if supportedPlatformLines.contains(where: { $0.contains("macosx") }) { platforms.insert(.macOS) }
      if supportedPlatformLines.contains(where: { $0.contains("iphoneos") }) { platforms.insert(.iOS) }
    }
    return platforms.isEmpty ? [.iOS] : platforms
  }

  // MARK: - Private Helpers

  private static func containsXcodeProject(at path: String) -> Bool {
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
    return items.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
  }

  /// Returns the path to the first .xcodeproj found at root or one subdir deep.
  private static func findXcodeproj(at path: String) -> String? {
    if let proj = firstXcodeproj(in: path) { return proj }
    guard let subdirs = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
    for sub in subdirs {
      var isDir: ObjCBool = false
      let full = (path as NSString).appendingPathComponent(sub)
      FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
      if isDir.boolValue, let proj = firstXcodeproj(in: full) { return proj }
    }
    return nil
  }

  private static func firstXcodeproj(in path: String) -> String? {
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
    guard let name = items.first(where: { $0.hasSuffix(".xcodeproj") }) else { return nil }
    return (path as NSString).appendingPathComponent(name)
  }
}
