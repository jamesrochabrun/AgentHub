import Foundation
@preconcurrency import AVFoundation
import SwiftOpenAI

@RealtimeActor
public protocol DictationRecording: AnyObject, Sendable {
  func startRecording() throws -> AsyncStream<AVAudioPCMBuffer>
  func stopRecording()
}

@RealtimeActor
public final class DictationRecorder: DictationRecording {
  private var audioEngine: AVAudioEngine?
  private var isRecording = false

  public init() {}

  public func startRecording() throws -> AsyncStream<AVAudioPCMBuffer> {
    if isRecording {
      stopRecording()
    }

    let engine = AVAudioEngine()
    audioEngine = engine
    configureBuiltInMicrophoneIfNeeded(for: engine)

    let inputNode = engine.inputNode
    let hardwareFormat = inputNode.inputFormat(forBus: 0)
    let format = hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0
      ? hardwareFormat
      : inputNode.outputFormat(forBus: 0)
    let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      continuation.yield(buffer)
    }
    engine.prepare()
    try engine.start()
    isRecording = true
    continuation.onTermination = { [weak self] _ in
      Task { @RealtimeActor in
        self?.stopRecording()
      }
    }
    return stream
  }

  public func stopRecording() {
    guard isRecording, let audioEngine else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    self.audioEngine = nil
    isRecording = false
  }

  private func configureBuiltInMicrophoneIfNeeded(for engine: AVAudioEngine) {
    var deviceID: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceID
    ) == noErr else {
      return
    }

    var transportType: UInt32 = 0
    propertySize = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyTransportType
    guard AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &propertySize,
      &transportType
    ) == noErr,
      transportType == kAudioDeviceTransportTypeBluetooth,
      let builtInMicrophoneID = findBuiltInMicrophone(),
      let audioUnit = engine.inputNode.audioUnit else {
      return
    }

    var inputDeviceID = builtInMicrophoneID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &inputDeviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    if status == noErr {
      AudioUnitUninitialize(audioUnit)
      AudioUnitInitialize(audioUnit)
    }
  }

  private func findBuiltInMicrophone() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var propertySize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize
    ) == noErr else {
      return nil
    }

    let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &devices
    ) == noErr else {
      return nil
    }

    return devices.first { device in
      var transportType: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      var transportAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      return AudioObjectGetPropertyData(
        device,
        &transportAddress,
        0,
        nil,
        &size,
        &transportType
      ) == noErr && transportType == kAudioDeviceTransportTypeBuiltIn
    }
  }
}
