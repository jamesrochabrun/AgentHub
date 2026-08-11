//
//  VoiceScreenCaptureService.swift
//  AgentHubVoice
//
//  Captures screenshots for voice conversations: a full display or a region,
//  across every connected monitor. Shots are written to a temp directory so
//  the voice agent can hand the file path to a coding session.
//

import CoreGraphics
import Foundation

#if canImport(ScreenCaptureKit)
import AppKit
import ScreenCaptureKit
#endif

// MARK: - Models

public struct VoiceCaptureDisplay: Codable, Equatable, Sendable {
  /// 1-based, ordered main display first.
  public let index: Int
  public let name: String
  public let width: Int
  public let height: Int
  public let isMain: Bool

  public init(index: Int, name: String, width: Int, height: Int, isMain: Bool) {
    self.index = index
    self.name = name
    self.width = width
    self.height = height
    self.isMain = isMain
  }
}

/// A capture region in points, relative to the chosen display's top-left corner.
public struct VoiceCaptureRegion: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct VoiceScreenCaptureResult: Codable, Equatable, Sendable {
  public let path: String
  public let display: VoiceCaptureDisplay
  public let region: VoiceCaptureRegion?

  public init(
    path: String,
    display: VoiceCaptureDisplay,
    region: VoiceCaptureRegion?
  ) {
    self.path = path
    self.display = display
    self.region = region
  }
}

public enum VoiceScreenCaptureError: Error, LocalizedError, Equatable {
  case permissionDenied
  case displayNotFound(Int)
  case invalidRegion
  case captureFailed(String)

  public var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Screen Recording permission is required. Grant it in System Settings."
    case .displayNotFound(let index):
      "There is no display \(index). Call list_displays for valid indexes."
    case .invalidRegion:
      "The requested region does not intersect the display."
    case .captureFailed(let reason):
      "Screen capture failed: \(reason)"
    }
  }
}

// MARK: - Protocol

public protocol VoiceScreenCapturing: Sendable {
  @MainActor func hasPermission() -> Bool
  @MainActor func requestPermission() -> Bool
  func listDisplays() async throws -> [VoiceCaptureDisplay]
  func capture(
    displayIndex: Int?,
    region: VoiceCaptureRegion?
  ) async throws -> VoiceScreenCaptureResult
}

// MARK: - Planner (pure, unit-tested)

public enum VoiceScreenCapturePlanner {
  /// Orders displays main-first so index 1 is always the main display, then
  /// keeps the system's order for external monitors.
  public static func orderMainFirst<Display>(
    _ displays: [Display],
    isMain: (Display) -> Bool
  ) -> [Display] {
    displays.filter(isMain) + displays.filter { !isMain($0) }
  }

  /// Resolves a 1-based display index; nil selects the main display (index 1).
  public static func selectionIndex(
    requested: Int?,
    displayCount: Int
  ) -> Int? {
    let index = requested ?? 1
    guard index >= 1, index <= displayCount else { return nil }
    return index
  }

  /// Clamps a region to the display bounds; nil when nothing remains.
  public static func clampedRegion(
    _ region: VoiceCaptureRegion,
    displayWidth: Double,
    displayHeight: Double
  ) -> CGRect? {
    let rect = CGRect(
      x: region.x,
      y: region.y,
      width: region.width,
      height: region.height
    )
    let bounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
    let clamped = rect.intersection(bounds)
    guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
      return nil
    }
    return clamped
  }
}

// MARK: - Live implementation

#if canImport(ScreenCaptureKit)
public struct VoiceScreenCaptureService: VoiceScreenCapturing {
  public init() {}

  @MainActor
  public func hasPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  @MainActor
  public func requestPermission() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  public func listDisplays() async throws -> [VoiceCaptureDisplay] {
    let displays = try await orderedDisplays()
    return displays.enumerated().map { offset, display in
      VoiceCaptureDisplay(
        index: offset + 1,
        name: displayName(for: display.displayID),
        width: display.width,
        height: display.height,
        isMain: display.displayID == CGMainDisplayID()
      )
    }
  }

  public func capture(
    displayIndex: Int?,
    region: VoiceCaptureRegion?
  ) async throws -> VoiceScreenCaptureResult {
    let displays = try await orderedDisplays()
    guard let index = VoiceScreenCapturePlanner.selectionIndex(
      requested: displayIndex,
      displayCount: displays.count
    ) else {
      throw VoiceScreenCaptureError.displayNotFound(displayIndex ?? 1)
    }
    let display = displays[index - 1]

    var clampedRegion: CGRect?
    if let region {
      guard let clamped = VoiceScreenCapturePlanner.clampedRegion(
        region,
        displayWidth: Double(display.width),
        displayHeight: Double(display.height)
      ) else {
        throw VoiceScreenCaptureError.invalidRegion
      }
      clampedRegion = clamped
    }

    let configuration = SCStreamConfiguration()
    let scale = backingScaleFactor(for: display.displayID)
    let sourceSize = clampedRegion?.size
      ?? CGSize(width: display.width, height: display.height)
    if let clampedRegion {
      configuration.sourceRect = clampedRegion
    }
    configuration.width = Int(sourceSize.width * scale)
    configuration.height = Int(sourceSize.height * scale)
    configuration.showsCursor = true

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let image: CGImage
    do {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
    } catch {
      throw VoiceScreenCaptureError.captureFailed(error.localizedDescription)
    }

    let path = try Self.writePNG(image)
    return VoiceScreenCaptureResult(
      path: path,
      display: VoiceCaptureDisplay(
        index: index,
        name: displayName(for: display.displayID),
        width: display.width,
        height: display.height,
        isMain: display.displayID == CGMainDisplayID()
      ),
      region: clampedRegion.map {
        VoiceCaptureRegion(
          x: $0.origin.x,
          y: $0.origin.y,
          width: $0.width,
          height: $0.height
        )
      }
    )
  }

  // MARK: - Private

  private func orderedDisplays() async throws -> [SCDisplay] {
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
    } catch {
      throw VoiceScreenCaptureError.permissionDenied
    }
    let mainID = CGMainDisplayID()
    return VoiceScreenCapturePlanner.orderMainFirst(content.displays) {
      $0.displayID == mainID
    }
  }

  private func displayName(for displayID: CGDirectDisplayID) -> String {
    let screen = NSScreen.screens.first { screen in
      (screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? CGDirectDisplayID) == displayID
    }
    return screen?.localizedName ?? "Display"
  }

  private func backingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
    let screen = NSScreen.screens.first { screen in
      (screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? CGDirectDisplayID) == displayID
    }
    return screen?.backingScaleFactor ?? 2
  }

  private static func writePNG(_ image: CGImage) throws -> String {
    let directory = URL(
      fileURLWithPath: NSTemporaryDirectory()
    ).appendingPathComponent("AgentHubVoiceShots", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    pruneOldShots(in: directory)

    let url = directory.appendingPathComponent(
      "shot-\(Int(Date().timeIntervalSince1970 * 1_000)).png"
    )
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      "public.png" as CFString,
      1,
      nil
    ) else {
      throw VoiceScreenCaptureError.captureFailed("Could not create PNG file.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw VoiceScreenCaptureError.captureFailed("Could not write PNG file.")
    }
    return url.path
  }

  private static func pruneOldShots(in directory: URL) {
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    for url in contents {
      let modified = (try? url.resourceValues(
        forKeys: [.contentModificationDateKey]
      ))?.contentModificationDate
      if let modified, modified < cutoff {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}
#endif
