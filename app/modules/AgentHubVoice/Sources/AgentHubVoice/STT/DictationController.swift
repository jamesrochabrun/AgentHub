import Foundation
import Observation
@preconcurrency import AVFoundation
import SwiftOpenAI

public enum DictationState: Equatable, Sendable {
  case idle
  case recording
  case transcribing
  case failed(String)
}

public typealias DictationRecorderFactory =
  @RealtimeActor @Sendable () -> any DictationRecording

@Observable
@MainActor
public final class DictationController {
  public private(set) var state: DictationState = .idle
  public private(set) var audioLevel: Float = 0
  public var onTranscript: (@MainActor @Sendable (String) -> Void)?

  private let transcriptionService: any TranscriptionService
  private let model: String
  private let recorderFactory: DictationRecorderFactory
  private let permissionRequester: @Sendable () async -> Bool
  private var recorder: (any DictationRecording)?
  private var recordingTask: Task<Void, Never>?
  private var buffers: [AVAudioPCMBuffer] = []

  public init(
    transcriptionService: any TranscriptionService,
    model: String = "whisper-1",
    recorderFactory: @escaping DictationRecorderFactory = { DictationRecorder() },
    permissionRequester: @escaping @Sendable () async -> Bool = {
      await MicrophoneAccess.request()
    }
  ) {
    self.transcriptionService = transcriptionService
    self.model = model
    self.recorderFactory = recorderFactory
    self.permissionRequester = permissionRequester
  }

  public func toggle() async {
    switch state {
    case .idle, .failed:
      await start()
    case .recording:
      await stopAndTranscribe()
    case .transcribing:
      break
    }
  }

  public func cancel() {
    recordingTask?.cancel()
    recordingTask = nil
    let recorder = self.recorder
    self.recorder = nil
    Task { @RealtimeActor in
      recorder?.stopRecording()
    }
    buffers.removeAll()
    state = .idle
    audioLevel = 0
  }

  private func start() async {
    guard await permissionRequester() else {
      state = .failed("Microphone permission is required for dictation.")
      return
    }
    buffers.removeAll()
    state = .recording

    do {
      let recorderAndStream: (any DictationRecording, AsyncStream<AVAudioPCMBuffer>) =
        try await Task { @RealtimeActor in
          let recorder = recorderFactory()
          return (recorder, try recorder.startRecording())
        }.value
      recorder = recorderAndStream.0
      recordingTask = Task { [weak self] in
        for await buffer in recorderAndStream.1 {
          guard !Task.isCancelled else { break }
          self?.buffers.append(buffer)
          self?.audioLevel = Self.rms(buffer)
        }
      }
    } catch {
      state = .failed("Recording failed: \(error.localizedDescription)")
    }
  }

  private func stopAndTranscribe() async {
    recordingTask?.cancel()
    recordingTask = nil
    let recorder = self.recorder
    self.recorder = nil
    await Task { @RealtimeActor in
      recorder?.stopRecording()
    }.value

    state = .transcribing
    audioLevel = 0
    do {
      let audioData = try WAVEncoder.encode(buffers: buffers)
      buffers.removeAll()
      let result = try await transcriptionService.transcribe(
        audioData: audioData,
        fileName: "recording.wav",
        model: model,
        responseFormat: "json"
      )
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      state = .idle
      if !text.isEmpty {
        onTranscript?(text)
      }
    } catch {
      buffers.removeAll()
      state = .failed("Transcription failed: \(error.localizedDescription)")
    }
  }

  private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }
    if let values = buffer.floatChannelData?[0] {
      var sum: Float = 0
      for index in 0..<count {
        sum += values[index] * values[index]
      }
      return min(1, sqrt(sum / Float(count)) * 5)
    }
    if let values = buffer.int16ChannelData?[0] {
      var sum: Float = 0
      for index in 0..<count {
        let sample = Float(values[index]) / Float(Int16.max)
        sum += sample * sample
      }
      return min(1, sqrt(sum / Float(count)) * 5)
    }
    return 0
  }
}

public enum MicrophoneAccess {
  public static func request() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}
