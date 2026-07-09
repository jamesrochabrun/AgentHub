import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Frames sampled from a finished simulator recording so agents that cannot
/// decode video (most CLI agents) can still see what happened on screen.
public struct SimulatorRecordingFrameSample: Codable, Equatable, Sendable {
  public let directory: String
  public let framePaths: [String]

  public init(directory: String, framePaths: [String]) {
    self.directory = directory
    self.framePaths = framePaths
  }
}

public protocol SimulatorRecordingFrameSampling: Sendable {
  func sampleFrames(fromVideoAt path: String, maxFrames: Int) async -> SimulatorRecordingFrameSample?
}

/// Extracts evenly spaced JPEG frames from a recording with AVFoundation.
/// No external tools (ffmpeg/ffprobe) are required, so the audit prompt can
/// always point the agent at images it is able to read directly.
public struct SimulatorRecordingFrameSampler: SimulatorRecordingFrameSampling {
  /// Frames are capped so the audit prompt stays small; longer recordings get
  /// wider spacing instead of more frames.
  public static let defaultMaxFrames = 10

  /// Longest edge of an extracted frame. Keeps files small while leaving
  /// on-screen text legible.
  private static let maxFrameDimension: CGFloat = 1200

  private static let jpegQuality: Double = 0.8

  public init() {}

  public func sampleFrames(
    fromVideoAt path: String,
    maxFrames: Int = Self.defaultMaxFrames
  ) async -> SimulatorRecordingFrameSample? {
    let videoURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }

    let asset = AVURLAsset(url: videoURL)
    guard let duration = try? await asset.load(.duration) else { return nil }

    let timestamps = Self.frameTimestamps(
      duration: duration.seconds,
      maxFrames: maxFrames
    )
    guard !timestamps.isEmpty else { return nil }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: Self.maxFrameDimension, height: Self.maxFrameDimension)

    let directoryURL = URL(
      fileURLWithPath: Self.frameDirectoryPath(forRecordingPath: path),
      isDirectory: true
    )
    do {
      if FileManager.default.fileExists(atPath: directoryURL.path) {
        try FileManager.default.removeItem(at: directoryURL)
      }
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    } catch {
      return nil
    }

    var framePaths: [String] = []
    for (index, seconds) in timestamps.enumerated() {
      let time = CMTime(seconds: seconds, preferredTimescale: 600)
      guard let (image, actualTime) = try? await generator.image(at: time) else { continue }
      let frameURL = directoryURL.appendingPathComponent(
        Self.frameFileName(index: index, seconds: actualTime.seconds.isFinite ? actualTime.seconds : seconds),
        isDirectory: false
      )
      if Self.writeJPEG(image, to: frameURL) {
        framePaths.append(frameURL.path)
      }
    }

    guard !framePaths.isEmpty else {
      try? FileManager.default.removeItem(at: directoryURL)
      return nil
    }

    return SimulatorRecordingFrameSample(directory: directoryURL.path, framePaths: framePaths)
  }

  /// Sibling directory that holds the sampled frames for a recording; derived
  /// from the recording path so deletion can clean it up without extra state.
  public static func frameDirectoryPath(forRecordingPath path: String) -> String {
    URL(fileURLWithPath: path)
      .deletingPathExtension()
      .path + "-frames"
  }

  /// Evenly spaced sample timestamps: roughly one per second, capped at
  /// `maxFrames`, always including the start and (near) end of the clip.
  static func frameTimestamps(duration: Double, maxFrames: Int) -> [Double] {
    guard maxFrames > 0 else { return [] }
    guard duration.isFinite, duration > 0 else { return [0] }

    // Request the final frame slightly before the clip ends; generating at
    // the exact duration commonly fails.
    let lastTimestamp = max(0, duration - 0.05)
    let count = min(maxFrames, max(2, Int(duration.rounded(.up)) + 1))
    guard count > 1, lastTimestamp > 0 else { return [0] }

    let step = lastTimestamp / Double(count - 1)
    var timestamps: [Double] = []
    for index in 0..<count {
      let timestamp = min(Double(index) * step, lastTimestamp)
      if timestamps.last != timestamp {
        timestamps.append(timestamp)
      }
    }
    return timestamps
  }

  static func frameFileName(index: Int, seconds: Double) -> String {
    String(format: "frame-%02d-%.1fs.jpg", index + 1, max(0, seconds))
  }

  private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      "public.jpeg" as CFString,
      1,
      nil
    ) else { return false }

    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
    )
    return CGImageDestinationFinalize(destination)
  }
}
