import Foundation
import Testing
@testable import AgentHubCore

// MARK: - Fixture

private struct XcodeProjectFixture {
  let root: URL

  /// Creates a temp directory with an optional .xcodeproj containing project.pbxproj.
  /// - Parameters:
  ///   - pbxprojContent: Content written into the project.pbxproj file. Pass nil to skip file creation.
  ///   - subdirName: When set, nests the .xcodeproj one directory level deeper.
  ///   - xcworkspace: When true, creates a .xcworkspace instead of .xcodeproj.
  static func create(
    pbxprojContent: String? = nil,
    subdirName: String? = nil,
    xcworkspace: Bool = false
  ) throws -> XcodeProjectFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("XcodeDetectorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let containerURL: URL
    if let sub = subdirName {
      containerURL = root.appendingPathComponent(sub)
      try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    } else {
      containerURL = root
    }

    let projectDirName = xcworkspace ? "App.xcworkspace" : "App.xcodeproj"
    let projectDir = containerURL.appendingPathComponent(projectDirName)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    if let content = pbxprojContent {
      let pbxproj = projectDir.appendingPathComponent("project.pbxproj")
      try content.write(to: pbxproj, atomically: true, encoding: .utf8)
    }

    return XcodeProjectFixture(root: root)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}

// MARK: - isXcodeProject

@Suite("isXcodeProject")
struct IsXcodeProjectTests {

  @Test func returnsTrueForXcodeprojAtRoot() throws {
    let fixture = try XcodeProjectFixture.create(pbxprojContent: "")
    defer { fixture.cleanup() }
    #expect(XcodeProjectDetector.isXcodeProject(at: fixture.root.path))
  }

  @Test func returnsTrueOneSubdirDeep() throws {
    let fixture = try XcodeProjectFixture.create(pbxprojContent: "", subdirName: "app")
    defer { fixture.cleanup() }
    #expect(XcodeProjectDetector.isXcodeProject(at: fixture.root.path))
  }

  @Test func returnsFalseForEmptyDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("XcodeDetectorEmpty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!XcodeProjectDetector.isXcodeProject(at: root.path))
  }

  @Test func returnsTrueForXcworkspaceAtRoot() throws {
    let fixture = try XcodeProjectFixture.create(pbxprojContent: "", xcworkspace: true)
    defer { fixture.cleanup() }
    #expect(XcodeProjectDetector.isXcodeProject(at: fixture.root.path))
  }
}

// MARK: - supportedPlatforms

@Suite("supportedPlatforms")
struct SupportedPlatformsTests {

  @Test func detectsIOSFromSDKRoot() throws {
    let content = """
      SDKROOT = iphoneos;
      """
    let fixture = try XcodeProjectFixture.create(pbxprojContent: content)
    defer { fixture.cleanup() }
    let platforms = XcodeProjectDetector.supportedPlatforms(at: fixture.root.path)
    #expect(platforms.contains(.iOS))
    #expect(!platforms.contains(.macOS))
  }

  @Test func detectsMacOSFromSDKRoot() throws {
    let content = """
      SDKROOT = macosx;
      """
    let fixture = try XcodeProjectFixture.create(pbxprojContent: content)
    defer { fixture.cleanup() }
    let platforms = XcodeProjectDetector.supportedPlatforms(at: fixture.root.path)
    #expect(platforms.contains(.macOS))
  }

  @Test func detectsBothFromSupportedPlatforms() throws {
    let content = """
      SDKROOT = auto;
      SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
      """
    let fixture = try XcodeProjectFixture.create(pbxprojContent: content)
    defer { fixture.cleanup() }
    let platforms = XcodeProjectDetector.supportedPlatforms(at: fixture.root.path)
    #expect(platforms.contains(.iOS))
    #expect(platforms.contains(.macOS))
  }

  @Test func fallsBackToIOSWhenNeitherKeyPresent() throws {
    let content = """
      PRODUCT_NAME = MyApp;
      """
    let fixture = try XcodeProjectFixture.create(pbxprojContent: content)
    defer { fixture.cleanup() }
    let platforms = XcodeProjectDetector.supportedPlatforms(at: fixture.root.path)
    #expect(platforms == [.iOS])
  }

  @Test func fallsBackToIOSWhenFileNotFound() throws {
    // Create the .xcodeproj dir but no project.pbxproj inside
    let fixture = try XcodeProjectFixture.create(pbxprojContent: nil)
    defer { fixture.cleanup() }
    let platforms = XcodeProjectDetector.supportedPlatforms(at: fixture.root.path)
    #expect(platforms == [.iOS])
  }

  @Test func findsProjectOneSubdirDeep() throws {
    let content = """
      SDKROOT = macosx;
      """
    let fixture = try XcodeProjectFixture.create(pbxprojContent: content, subdirName: "app")
    defer { fixture.cleanup() }
    let platforms = XcodeProjectDetector.supportedPlatforms(at: fixture.root.path)
    #expect(platforms.contains(.macOS))
  }
}
