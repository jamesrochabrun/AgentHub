import AVFoundation
import Testing
@testable import AgentHubVoice

struct RealtimeVoiceEngineLevelTests {
  private func makeInt16Buffer(sample: Int16) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 24000,
      channels: 1,
      interleaved: false
    )!
    let frames: AVAudioFrameCount = 240
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if let data = buffer.int16ChannelData {
      for frame in 0..<Int(frames) {
        data[0][frame] = sample
      }
    }
    return buffer
  }

  @Test
  func rmsReadsPCM16Buffers() {
    // The microphone vendor delivers Int16 buffers; the level meter must not
    // silently read 0 for them.
    let level = RealtimeVoiceEngine.rms(makeInt16Buffer(sample: 8000))
    #expect(level > 0.5)
  }

  @Test
  func rmsIsZeroForDigitalSilence() {
    #expect(RealtimeVoiceEngine.rms(makeInt16Buffer(sample: 0)) == 0)
  }

  @Test
  func rmsReadsFloatBuffers() {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 24000,
      channels: 1,
      interleaved: false
    )!
    let frames: AVAudioFrameCount = 240
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if let data = buffer.floatChannelData {
      for frame in 0..<Int(frames) {
        data[0][frame] = 0.25
      }
    }
    #expect(RealtimeVoiceEngine.rms(buffer) > 0.5)
  }
}
