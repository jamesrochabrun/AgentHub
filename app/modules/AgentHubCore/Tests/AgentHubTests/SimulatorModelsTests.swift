import AgentHubCLIKit
@testable import AgentHubCore
import Foundation
import Testing

// MARK: - SimulatorDevice

@Suite("SimulatorDevice")
struct SimulatorDeviceTests {
  @Test func isBootedTrueWhenStateEqualsBooted() {
    let device = SimulatorDevice(
      udid: "ABCD-1234",
      name: "iPhone 15",
      state: "Booted",
      isAvailable: true,
      deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15"
    )
    #expect(device.isBooted == true)
  }

  @Test func isBootedFalseForShutdownState() {
    let device = SimulatorDevice(
      udid: "ABCD-1234",
      name: "iPhone 15",
      state: "Shutdown",
      isAvailable: true,
      deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15"
    )
    #expect(device.isBooted == false)
  }

  @Test func idEqualsUdid() {
    let udid = "EFGH-5678"
    let device = SimulatorDevice(
      udid: udid,
      name: "iPhone 14",
      state: "Shutdown",
      isAvailable: true,
      deviceTypeIdentifier: ""
    )
    #expect(device.id == udid)
  }
}

// MARK: - SimulatorRuntime

@Suite("SimulatorRuntime")
struct SimulatorRuntimeTests {
  @Test func availableDevicesFiltersUnavailableOnes() {
    let available = SimulatorDevice(
      udid: "A1",
      name: "iPhone 15",
      state: "Shutdown",
      isAvailable: true,
      deviceTypeIdentifier: ""
    )
    let unavailable = SimulatorDevice(
      udid: "A2",
      name: "iPhone 12",
      state: "Shutdown",
      isAvailable: false,
      deviceTypeIdentifier: ""
    )
    let runtime = SimulatorRuntime(
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
      displayName: "iOS 17.5",
      devices: [available, unavailable]
    )
    #expect(runtime.availableDevices.count == 1)
    #expect(runtime.availableDevices.first?.udid == "A1")
  }

  @Test func availableDevicesEmptyWhenAllUnavailable() {
    let device = SimulatorDevice(
      udid: "X1",
      name: "iPhone 8",
      state: "Shutdown",
      isAvailable: false,
      deviceTypeIdentifier: ""
    )
    let runtime = SimulatorRuntime(
      identifier: "com.apple.CoreSimulator.SimRuntime.iOS-16-0",
      displayName: "iOS 16.0",
      devices: [device]
    )
    #expect(runtime.availableDevices.isEmpty)
  }

  @Test func idEqualsIdentifier() {
    let identifier = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    let runtime = SimulatorRuntime(identifier: identifier, displayName: "iOS 17.5", devices: [])
    #expect(runtime.id == identifier)
  }
}

// MARK: - PhysicalIOSDevice

@Suite("PhysicalIOSDevice")
struct PhysicalIOSDeviceTests {
  @Test func idEqualsIdentifier() {
    let device = PhysicalIOSDevice(
      identifier: "00008150",
      name: "Zizou2",
      modelName: "iPhone 17 Pro",
      operatingSystemVersion: "26.5 (23F77)",
      interface: "usb"
    )

    #expect(device.id == "00008150")
  }

  @Test func subtitleIncludesDistinctModelAndOSVersion() {
    let device = PhysicalIOSDevice(
      identifier: "00008150",
      name: "Zizou2",
      modelName: "iPhone 17 Pro",
      operatingSystemVersion: "26.5 (23F77)",
      interface: "usb"
    )

    #expect(device.subtitle == "iPhone 17 Pro - 26.5 (23F77)")
  }

  @Test func subtitleAvoidsDuplicateModelName() {
    let device = PhysicalIOSDevice(
      identifier: "00008150",
      name: "iPhone 17 Pro",
      modelName: "iPhone 17 Pro",
      operatingSystemVersion: "26.5 (23F77)",
      interface: nil
    )

    #expect(device.subtitle == "26.5 (23F77)")
  }
}

// MARK: - SimulatorState

@Suite("SimulatorState")
struct SimulatorStateTests {
  @Test func equalityForSimpleCases() {
    #expect(SimulatorState.idle == .idle)
    #expect(SimulatorState.booting == .booting)
    #expect(SimulatorState.building == .building)
    #expect(SimulatorState.installing == .installing)
    #expect(SimulatorState.launching == .launching)
    #expect(SimulatorState.booted == .booted)
    #expect(SimulatorState.shuttingDown == .shuttingDown)
    #expect(SimulatorState.booted != .idle)
    #expect(SimulatorState.booting != .booted)
    #expect(SimulatorState.installing != .launching)
  }

  @Test func failedEqualityMatchesErrorString() {
    #expect(SimulatorState.failed(error: "oops") == .failed(error: "oops"))
  }

  @Test func failedInequalityOnDifferentErrors() {
    #expect(SimulatorState.failed(error: "x") != .failed(error: "y"))
  }
}

// MARK: - MacRunState

@Suite("MacRunState")
struct MacRunStateTests {
  @Test func equalityForAllCases() {
    #expect(MacRunState.idle == .idle)
    #expect(MacRunState.building == .building)
    #expect(MacRunState.done == .done)
    #expect(MacRunState.idle != .building)
    #expect(MacRunState.done != .idle)
  }

  @Test func failedAssociatedValueIsCompared() {
    #expect(MacRunState.failed(error: "err") == .failed(error: "err"))
    #expect(MacRunState.failed(error: "a") != .failed(error: "b"))
  }
}

// MARK: - XcodePlatform

@Suite("XcodePlatform")
struct XcodePlatformTests {
  @Test func hashableInSet() {
    var set: Set<XcodePlatform> = []
    set.insert(.iOS)
    set.insert(.iOS)
    #expect(set.count == 1)
  }

  @Test func setWithBothPlatforms() {
    let set: Set<XcodePlatform> = [.iOS, .macOS]
    #expect(set.count == 2)
    #expect(set.contains(.iOS))
    #expect(set.contains(.macOS))
  }
}

// MARK: - SimulatorBuildErrorPromptBuilder

@Suite("SimulatorBuildErrorPromptBuilder")
struct SimulatorBuildErrorPromptBuilderTests {
  @Test func wrapsCompilerErrorForAgentRepair() {
    let error = "/tmp/App/ContentView.swift:12:3: error: cannot find 'foo' in scope"

    let prompt = SimulatorBuildErrorPromptBuilder.prompt(for: error)

    #expect(prompt == """
    Fix this simulator build/run error:
    /tmp/App/ContentView.swift:12:3: error: cannot find 'foo' in scope
    """)
  }

  @Test func preservesMultiLineErrorDetails() {
    let error = """
    ContentView.swift:9:7: error: type 'Demo' has no member 'missing'
    simctl launch failed (exit 4)
    """

    let prompt = SimulatorBuildErrorPromptBuilder.prompt(for: error)

    #expect(prompt.contains("ContentView.swift:9:7: error: type 'Demo' has no member 'missing'"))
    #expect(prompt.contains("simctl launch failed (exit 4)"))
  }
}

// MARK: - SimulatorRecordingPanelState

@Suite("SimulatorRecordingPanelState")
struct SimulatorRecordingPanelStateTests {
  @Test func sentStateIsNeitherBusyNorRecording() {
    let state = SimulatorRecordingPanelState.sent(outputPath: "/tmp/demo.mp4")

    #expect(state.isBusy == false)
    #expect(state.isRecording == false)
    #expect(state.activeRecording == nil)
  }

  @Test func sentStateEqualityComparesOutputPath() {
    #expect(SimulatorRecordingPanelState.sent(outputPath: "/tmp/a.mp4")
      == .sent(outputPath: "/tmp/a.mp4"))
    #expect(SimulatorRecordingPanelState.sent(outputPath: "/tmp/a.mp4")
      != .sent(outputPath: "/tmp/b.mp4"))
    #expect(SimulatorRecordingPanelState.sent(outputPath: "/tmp/a.mp4") != .idle)
  }
}

// MARK: - SimulatorRecordingPromptBuilder

@Suite("SimulatorRecordingPromptBuilder")
struct SimulatorRecordingPromptBuilderTests {
  @Test func includesRecordingPathAndFFmpegGuidance() {
    let prompt = SimulatorRecordingPromptBuilder.prompt(
      for: SimulatorRecordingResult(
        udid: "UDID-1",
        outputPath: "/tmp/demo.mp4",
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_012),
        duration: 12,
        fileExists: true,
        fileSizeBytes: 1_024,
        isFinalized: true,
        validationError: nil
      ),
      deviceName: "iPhone 17 Pro",
      issue: "The answer buttons jump after the recording starts."
    )

    #expect(prompt.contains("/tmp/demo.mp4"))
    #expect(prompt.contains("The answer buttons jump after the recording starts."))
    #expect(prompt.contains("ffprobe or ffmpeg"))
    #expect(prompt.contains("Device: iPhone 17 Pro"))
    #expect(prompt.contains("Duration: 12.0 seconds"))
  }

  @Test func listsSampledFramesWhenAvailable() {
    let prompt = SimulatorRecordingPromptBuilder.prompt(
      for: SimulatorRecordingResult(
        udid: "UDID-1",
        outputPath: "/tmp/demo.mp4",
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_012),
        duration: 12,
        fileExists: true,
        fileSizeBytes: 1_024,
        isFinalized: true,
        validationError: nil
      ),
      deviceName: nil,
      issue: "The tab bar flickers while scrolling.",
      sampledFrames: SimulatorRecordingFrameSample(
        directory: "/tmp/demo-frames",
        framePaths: [
          "/tmp/demo-frames/frame-01-0.0s.jpg",
          "/tmp/demo-frames/frame-02-6.0s.jpg",
        ]
      )
    )

    #expect(prompt.contains("/tmp/demo.mp4"))
    #expect(prompt.contains("/tmp/demo-frames/frame-01-0.0s.jpg"))
    #expect(prompt.contains("/tmp/demo-frames/frame-02-6.0s.jpg"))
    #expect(prompt.contains("read these directly as images"))
    #expect(prompt.contains("only if you need finer timing"))
  }

  @Test func fallsBackToFFmpegGuidanceWithoutSampledFrames() {
    let prompt = SimulatorRecordingPromptBuilder.prompt(
      for: SimulatorRecordingResult(
        udid: "UDID-1",
        outputPath: "/tmp/demo.mp4",
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_012),
        duration: 12,
        fileExists: true,
        fileSizeBytes: 1_024,
        isFinalized: true,
        validationError: nil
      ),
      deviceName: nil,
      issue: "The tab bar flickers while scrolling.",
      sampledFrames: nil
    )

    #expect(prompt.contains("Use ffprobe or ffmpeg to inspect timing and sampled frames"))
    #expect(!prompt.contains("read these directly as images"))
  }

  @Test func explainsWhenRecordingIsNotFinalized() {
    let prompt = SimulatorRecordingPromptBuilder.prompt(
      for: SimulatorRecordingResult(
        udid: "UDID-1",
        outputPath: "/tmp/demo.mp4",
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 1_001),
        duration: 1,
        fileExists: true,
        fileSizeBytes: 1_024,
        isFinalized: false,
        validationError: "The MP4 file did not finalize correctly; missing top-level moov atom."
      ),
      deviceName: nil,
      issue: "The recording fails when I stop capture."
    )

    #expect(prompt.contains("could not be audited"))
    #expect(prompt.contains("The recording fails when I stop capture."))
    #expect(prompt.contains("missing top-level moov atom"))
  }
}
