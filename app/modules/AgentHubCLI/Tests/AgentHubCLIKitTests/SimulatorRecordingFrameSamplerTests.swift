import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SimulatorRecordingFrameSampler")
struct SimulatorRecordingFrameSamplerTests {
  @Test("Timestamps are empty when no frames are requested")
  func timestampsEmptyForZeroMaxFrames() {
    #expect(SimulatorRecordingFrameSampler.frameTimestamps(duration: 10, maxFrames: 0).isEmpty)
  }

  @Test("Zero or invalid durations sample a single leading frame")
  func timestampsForInvalidDurations() {
    #expect(SimulatorRecordingFrameSampler.frameTimestamps(duration: 0, maxFrames: 10) == [0])
    #expect(SimulatorRecordingFrameSampler.frameTimestamps(duration: -3, maxFrames: 10) == [0])
    #expect(SimulatorRecordingFrameSampler.frameTimestamps(duration: .nan, maxFrames: 10) == [0])
  }

  @Test("Long recordings cap at maxFrames and stay evenly spaced")
  func timestampsCapAtMaxFrames() {
    let timestamps = SimulatorRecordingFrameSampler.frameTimestamps(duration: 60, maxFrames: 10)

    #expect(timestamps.count == 10)
    #expect(timestamps.first == 0)
    #expect(timestamps.last.map { abs($0 - 59.95) < 0.001 } == true)
    #expect(timestamps == timestamps.sorted())
    #expect(Set(timestamps).count == timestamps.count)
  }

  @Test("Short recordings sample roughly one frame per second")
  func timestampsScaleWithDuration() {
    let timestamps = SimulatorRecordingFrameSampler.frameTimestamps(duration: 2, maxFrames: 10)

    #expect(timestamps.count == 3)
    #expect(timestamps.first == 0)
    #expect(timestamps.last.map { abs($0 - 1.95) < 0.001 } == true)
  }

  @Test("Sub-second recordings keep a start and end frame")
  func timestampsForSubSecondClip() {
    let timestamps = SimulatorRecordingFrameSampler.frameTimestamps(duration: 0.3, maxFrames: 10)

    #expect(timestamps.count == 2)
    #expect(timestamps.first == 0)
    #expect(timestamps.last.map { abs($0 - 0.25) < 0.001 } == true)
  }

  @Test("Frame directory sits beside the recording")
  func frameDirectoryPathDerivedFromRecording() {
    let path = SimulatorRecordingFrameSampler.frameDirectoryPath(
      forRecordingPath: "/tmp/recordings/demo.mp4"
    )

    #expect(path == "/tmp/recordings/demo-frames")
  }

  @Test("Frame file names carry ordinal and timestamp")
  func frameFileNameFormat() {
    #expect(SimulatorRecordingFrameSampler.frameFileName(index: 0, seconds: 0) == "frame-01-0.0s.jpg")
    #expect(SimulatorRecordingFrameSampler.frameFileName(index: 4, seconds: 3.24) == "frame-05-3.2s.jpg")
  }

  @Test("Sampling a missing file returns nil")
  func samplingMissingFileReturnsNil() async {
    let sample = await SimulatorRecordingFrameSampler().sampleFrames(
      fromVideoAt: "/tmp/does-not-exist-\(UUID().uuidString).mp4",
      maxFrames: 4
    )

    #expect(sample == nil)
  }

  @Test("Sampling a real MP4 writes readable JPEG frames beside it")
  func samplingRealVideoWritesFrames() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-frame-sampler-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let videoURL = directory.appendingPathComponent("clip.mp4")
    try await writeTestVideo(to: videoURL, frameCount: 12, framesPerSecond: 6)

    let sample = await SimulatorRecordingFrameSampler().sampleFrames(
      fromVideoAt: videoURL.path,
      maxFrames: 5
    )

    let unwrapped = try #require(sample)
    #expect(unwrapped.directory == directory.appendingPathComponent("clip-frames").path)
    #expect(unwrapped.framePaths.count >= 2)
    for framePath in unwrapped.framePaths {
      #expect(framePath.hasPrefix(unwrapped.directory))
      #expect(framePath.hasSuffix(".jpg"))
      let attributes = try FileManager.default.attributesOfItem(atPath: framePath)
      #expect(((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0)
    }

    try SimulatorRecordingService.deleteRecordingFile(at: videoURL.path)
    #expect(FileManager.default.fileExists(atPath: videoURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: unwrapped.directory) == false)
  }

  @Test("Deleting a recording removes an orphaned frames directory")
  func deleteRecordingRemovesFramesDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-frame-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let videoURL = directory.appendingPathComponent("clip.mp4")
    let framesURL = directory.appendingPathComponent("clip-frames", isDirectory: true)
    try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
    try Data([0x00]).write(to: videoURL)
    try Data([0x01]).write(to: framesURL.appendingPathComponent("frame-01-0.0s.jpg"))

    try SimulatorRecordingService.deleteRecordingFile(at: videoURL.path)

    #expect(FileManager.default.fileExists(atPath: videoURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: framesURL.path) == false)
  }
}

/// Encodes a tiny solid-color H.264 MP4 so sampling runs against a real,
/// finalized video rather than a fixture checked into the repo.
private func writeTestVideo(
  to url: URL,
  frameCount: Int,
  framesPerSecond: Int32
) async throws {
  let width = 320
  let height = 240
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ]
  )
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
  )
  writer.add(input)

  guard writer.startWriting() else {
    throw writer.error ?? CocoaError(.fileWriteUnknown)
  }
  writer.startSession(atSourceTime: .zero)

  for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData {
      try await Task.sleep(for: .milliseconds(10))
    }

    guard let pool = adaptor.pixelBufferPool else {
      throw CocoaError(.fileWriteUnknown)
    }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    guard let pixelBuffer else {
      throw CocoaError(.fileWriteUnknown)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(baseAddress, Int32((frame * 19) % 255), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let presentationTime = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
    adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
  }

  input.markAsFinished()
  await writer.finishWriting()
  guard writer.status == .completed else {
    throw writer.error ?? CocoaError(.fileWriteUnknown)
  }
}
