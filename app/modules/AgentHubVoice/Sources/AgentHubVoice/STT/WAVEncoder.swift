import AVFoundation
import Foundation

public enum WAVEncoderError: LocalizedError {
  case noAudio
  case unsupportedBufferFormat

  public var errorDescription: String? {
    switch self {
    case .noAudio:
      "No audio was recorded."
    case .unsupportedBufferFormat:
      "The microphone produced an unsupported audio format."
    }
  }
}

public enum WAVEncoder {
  public static func encode(
    samples: [Int16],
    sampleRate: UInt32,
    channels: UInt16 = 1
  ) throws -> Data {
    guard !samples.isEmpty else {
      throw WAVEncoderError.noAudio
    }

    let bitsPerSample: UInt16 = 16
    let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)

    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    append(UInt32(36) + dataSize, to: &data)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    append(UInt32(16), to: &data)
    append(UInt16(1), to: &data)
    append(channels, to: &data)
    append(sampleRate, to: &data)
    append(byteRate, to: &data)
    append(blockAlign, to: &data)
    append(bitsPerSample, to: &data)
    data.append(contentsOf: "data".utf8)
    append(dataSize, to: &data)
    for sample in samples {
      append(sample, to: &data)
    }
    return data
  }

  public static func encode(buffers: [AVAudioPCMBuffer]) throws -> Data {
    guard let first = buffers.first else {
      throw WAVEncoderError.noAudio
    }
    var samples: [Int16] = []
    for buffer in buffers {
      let frameCount = Int(buffer.frameLength)
      if let floatData = buffer.floatChannelData {
        for index in 0..<frameCount {
          let clamped = max(-1, min(1, floatData[0][index]))
          samples.append(Int16(clamped * Float(Int16.max)))
        }
      } else if let int16Data = buffer.int16ChannelData {
        for index in 0..<frameCount {
          samples.append(int16Data[0][index])
        }
      } else {
        throw WAVEncoderError.unsupportedBufferFormat
      }
    }
    return try encode(
      samples: samples,
      sampleRate: UInt32(first.format.sampleRate)
    )
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
      data.append(contentsOf: bytes)
    }
  }
}
