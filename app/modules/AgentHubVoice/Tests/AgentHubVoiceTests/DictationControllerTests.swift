import AVFoundation
import SwiftOpenAI
import Testing
@testable import AgentHubVoice

private actor MockTranscriptionService: TranscriptionService {
  private(set) var receivedModel: String?

  func transcribe(
    audioData: Data,
    fileName: String,
    model: String,
    responseFormat: String?
  ) async throws -> TranscriptionResult {
    receivedModel = model
    return TranscriptionResult(text: "  dictated prompt  ")
  }
}

@RealtimeActor
private final class MockDictationRecorder: DictationRecording {
  private let stream: AsyncStream<AVAudioPCMBuffer>

  init() {
    let format = AVAudioFormat(
      standardFormatWithSampleRate: 24_000,
      channels: 1
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
    buffer.frameLength = 4
    buffer.floatChannelData?[0][0] = 0.1
    buffer.floatChannelData?[0][1] = -0.1
    buffer.floatChannelData?[0][2] = 0.2
    buffer.floatChannelData?[0][3] = -0.2
    stream = AsyncStream { continuation in
      continuation.yield(buffer)
      continuation.finish()
    }
  }

  func startRecording() throws -> AsyncStream<AVAudioPCMBuffer> {
    stream
  }

  func stopRecording() {}
}

@MainActor
struct DictationControllerTests {
  @Test
  func recordsTranscribesAndPassesConfiguredModel() async {
    let service = MockTranscriptionService()
    let controller = DictationController(
      transcriptionService: service,
      model: "whisper-1",
      recorderFactory: { MockDictationRecorder() },
      permissionRequester: { true }
    )
    var transcript: String?
    controller.onTranscript = { transcript = $0 }

    await controller.toggle()
    await waitUntil { controller.audioLevel > 0 }
    await controller.toggle()

    #expect(controller.state == .idle)
    #expect(transcript == "dictated prompt")
    #expect(await service.receivedModel == "whisper-1")
  }

  @Test
  func permissionDenialProducesActionableFailure() async {
    let controller = DictationController(
      transcriptionService: MockTranscriptionService(),
      permissionRequester: { false }
    )

    await controller.toggle()

    guard case .failed(let message) = controller.state else {
      Issue.record("Expected failed state")
      return
    }
    #expect(message.contains("Microphone permission"))
  }

  private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<100 where !predicate() {
      await Task.yield()
    }
  }
}
