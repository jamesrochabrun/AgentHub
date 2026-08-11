import Foundation
import Testing
@testable import AgentHubVoice

struct WAVEncoderTests {
  @Test
  func writesValidPCMHeaderAndSamples() throws {
    let data = try WAVEncoder.encode(
      samples: [0, Int16.max, Int16.min],
      sampleRate: 24_000
    )

    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
    #expect(data.count == 44 + 6)
    #expect(littleEndianUInt32(data, offset: 24) == 24_000)
    #expect(littleEndianUInt32(data, offset: 40) == 6)
  }

  @Test
  func rejectsEmptyAudio() {
    #expect(throws: WAVEncoderError.self) {
      try WAVEncoder.encode(samples: [], sampleRate: 24_000)
    }
  }

  private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
      | UInt32(data[offset + 1]) << 8
      | UInt32(data[offset + 2]) << 16
      | UInt32(data[offset + 3]) << 24
  }
}
