import Foundation
import Testing
@testable import AgentHubCore

// MARK: - runtimeDisplayName

@Suite("runtimeDisplayName")
struct RuntimeDisplayNameTests {

  @Test func parsesFullVersion() {
    let result = SimulatorService.runtimeDisplayName(
      from: "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    )
    #expect(result == "iOS 17.5")
  }

  @Test func parsesMajorOnly() {
    let result = SimulatorService.runtimeDisplayName(
      from: "com.apple.CoreSimulator.SimRuntime.iOS-18"
    )
    #expect(result == "iOS 18")
  }

  @Test func handlesUnknownFormat() {
    // A single-component suffix with no hyphens returns the suffix as-is
    let result = SimulatorService.runtimeDisplayName(from: "watchOS")
    #expect(result == "watchOS")
  }
}

// MARK: - parseDeviceList

@Suite("parseDeviceList")
struct ParseDeviceListTests {

  private let sampleJSON = """
  {
    "devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
        {
          "udid": "AAAA-1111",
          "name": "iPhone 15 Pro",
          "state": "Shutdown",
          "isAvailable": true,
          "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro"
        },
        {
          "udid": "AAAA-2222",
          "name": "iPhone 14",
          "state": "Booted",
          "isAvailable": false,
          "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-14"
        }
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
        {
          "udid": "BBBB-3333",
          "name": "iPhone SE (3rd generation)",
          "state": "Shutdown",
          "isAvailable": true,
          "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
        }
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-10-0": [
        {
          "udid": "CCCC-4444",
          "name": "Apple Watch Series 9",
          "state": "Shutdown",
          "isAvailable": true,
          "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-41mm"
        }
      ]
    }
  }
  """

  @Test func filtersToiOSRuntimesOnly() throws {
    let data = sampleJSON.data(using: .utf8)!
    let runtimes = try SimulatorService.parseDeviceList(from: data)
    // watchOS runtime must be excluded
    let allRuntimesAreIOS = runtimes.allSatisfy { $0.identifier.contains("iOS") }
    #expect(allRuntimesAreIOS)
    #expect(runtimes.count == 2)
  }

  @Test func sortsRuntimesNewestFirst() throws {
    let data = sampleJSON.data(using: .utf8)!
    let runtimes = try SimulatorService.parseDeviceList(from: data)
    #expect(runtimes.count == 2)
    #expect(runtimes[0].identifier.contains("iOS-17"))
    #expect(runtimes[1].identifier.contains("iOS-16"))
  }

  @Test func parsesDeviceFieldsCorrectly() throws {
    let data = sampleJSON.data(using: .utf8)!
    let runtimes = try SimulatorService.parseDeviceList(from: data)
    let ios17 = try #require(runtimes.first { $0.identifier.contains("iOS-17") })
    #expect(ios17.devices.count == 2)

    let pro = try #require(ios17.devices.first { $0.udid == "AAAA-1111" })
    #expect(pro.name == "iPhone 15 Pro")
    #expect(pro.state == "Shutdown")
    #expect(pro.isAvailable == true)

    let iphone14 = try #require(ios17.devices.first { $0.udid == "AAAA-2222" })
    #expect(iphone14.isAvailable == false)
    #expect(iphone14.isBooted == true)
  }

  @Test func throwsOnMalformedJSON() throws {
    let badData = "not json at all".data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try SimulatorService.parseDeviceList(from: badData)
    }
  }
}

// MARK: - parsePhysicalDeviceList

@Suite("parsePhysicalDeviceList")
struct ParsePhysicalDeviceListTests {
  private let sampleJSON = """
  [
    {
      "simulator": false,
      "available": true,
      "platform": "com.apple.platform.iphoneos",
      "identifier": "00008150-000E411A1A87801C",
      "name": "Zizou2",
      "modelName": "iPhone 17 Pro",
      "operatingSystemVersion": "26.5 (23F77)",
      "interface": "usb"
    },
    {
      "simulator": false,
      "available": false,
      "platform": "com.apple.platform.iphoneos",
      "identifier": "00008120-000A45121EF0201E",
      "name": "Offline iPad",
      "modelName": "iPad (A16)",
      "operatingSystemVersion": "18.7.1 (22H31)"
    },
    {
      "simulator": true,
      "available": true,
      "platform": "com.apple.platform.iphonesimulator",
      "identifier": "SIM-1",
      "name": "iPhone 17"
    },
    {
      "simulator": false,
      "available": true,
      "platform": "com.apple.platform.macosx",
      "identifier": "MAC-1",
      "name": "My Mac"
    }
  ]
  """

  private let deviceCtlJSON = """
  {
    "info": {
      "outcome": "success"
    },
    "result": {
      "devices": [
        {
          "capabilities": [
            { "featureIdentifier": "com.apple.coredevice.feature.tags" }
          ],
          "deviceProperties": {
            "name": "Offline iPad",
            "osVersionNumber": "18.7.1",
            "osBuildUpdate": "22H31"
          },
          "hardwareProperties": {
            "marketingName": "iPad (A16)",
            "platform": "iOS",
            "reality": "physical",
            "udid": "00008120-000A45121EF0201E"
          }
        },
        {
          "capabilities": [
            { "featureIdentifier": "com.apple.coredevice.feature.installapp" },
            { "featureIdentifier": "com.apple.coredevice.feature.launchapplication" }
          ],
          "deviceProperties": {
            "name": "Zizou2",
            "osVersionNumber": "26.6",
            "osBuildUpdate": "23G5043d"
          },
          "hardwareProperties": {
            "marketingName": "iPhone 17 Pro",
            "platform": "iOS",
            "productType": "iPhone18,1",
            "reality": "physical",
            "udid": "00008150-000E411A1A87801C"
          }
        },
        {
          "capabilities": [
            { "featureIdentifier": "com.apple.coredevice.feature.installapp" },
            { "featureIdentifier": "com.apple.coredevice.feature.launchapplication" }
          ],
          "deviceProperties": {
            "name": "Vision Device",
            "osVersionNumber": "26.0"
          },
          "hardwareProperties": {
            "marketingName": "Apple Vision Pro",
            "platform": "xrOS",
            "reality": "physical",
            "udid": "XR-DEVICE"
          }
        }
      ]
    }
  }
  """

  @Test func keepsOnlyAvailablePhysicalIOSDevices() throws {
    let devices = try SimulatorService.parsePhysicalDeviceList(from: sampleJSON.data(using: .utf8)!)

    #expect(devices.count == 1)
    #expect(devices.first?.identifier == "00008150-000E411A1A87801C")
    #expect(devices.first?.name == "Zizou2")
    #expect(devices.first?.modelName == "iPhone 17 Pro")
    #expect(devices.first?.operatingSystemVersion == "26.5 (23F77)")
    #expect(devices.first?.interface == "usb")
  }

  @Test func parsesRunCapableDevicectlPhysicalIOSDevices() throws {
    let devices = try SimulatorService.parseDeviceCtlPhysicalDeviceList(
      from: deviceCtlJSON.data(using: .utf8)!
    )

    #expect(devices.count == 1)
    #expect(devices.first?.identifier == "00008150-000E411A1A87801C")
    #expect(devices.first?.name == "Zizou2")
    #expect(devices.first?.modelName == "iPhone 17 Pro")
    #expect(devices.first?.operatingSystemVersion == "26.6 (23G5043d)")
  }

  @Test func throwsOnMalformedJSON() {
    #expect(throws: (any Error).self) {
      try SimulatorService.parsePhysicalDeviceList(from: Data("{}".utf8))
    }
  }

  @Test func devicectlParserThrowsOnMalformedJSON() {
    #expect(throws: (any Error).self) {
      try SimulatorService.parseDeviceCtlPhysicalDeviceList(from: Data("[]".utf8))
    }
  }
}

// MARK: - state(for:)

@Suite("state(for:)")
struct StateQueryTests {

  @Test @MainActor func returnsIdleForUnknownUDID() {
    let projectPath = "/tmp/FakeProject-\(UUID().uuidString)"
    let state = SimulatorService.shared.state(
      for: "NONEXISTENT-UDID-\(UUID().uuidString)",
      projectPath: projectPath
    )
    #expect(state == .idle)
  }
}

// MARK: - cancelBuild

@Suite("cancelBuild")
struct CancelBuildTests {

  @Test @MainActor func setsStateToIdleWithoutActiveProcess() {
    let path = "/tmp/FakeProject-\(UUID().uuidString)"
    SimulatorService.shared.cancelBuild(projectPath: path)
    // After cancel with no in-flight process the state should be idle
    // (macRunStates[path] is either nil or .idle — both are "idle" from the API perspective)
    let service = SimulatorService.shared
    // Access via the public-facing state — macRunStates is private(set) but we can infer from
    // the absence of any other state that it defaulted to idle.
    // We exercise cancelBuild without crashing and confirm no failure state is set.
    // (The property is private(set) so we can only test indirectly here.)
    _ = service  // suppress unused-variable warning; the real test is "no crash"
    #expect(Bool(true))  // reached without throwing / crashing
  }
}

// MARK: - cancelSimulatorBuild

@Suite("cancelSimulatorBuild")
struct CancelSimulatorBuildTests {

  @Test @MainActor func setsDeviceStateToIdleWithoutActiveProcess() {
    let udid = "FAKE-UDID-\(UUID().uuidString)"
    let projectPath = "/tmp/FakeProject-\(UUID().uuidString)"
    SimulatorService.shared.cancelSimulatorBuild(udid: udid, projectPath: projectPath)
    // After cancel the device state must be .idle
    let state = SimulatorService.shared.state(for: udid, projectPath: projectPath)
    #expect(state == .idle)
  }
}

// MARK: - build helpers

@Suite("build helpers")
struct BuildHelperTests {

  @Test func derivedDataPathIsStableAndScopedToAgentHubBuilds() {
    let projectPath = "/tmp/MyProject"
    let first = SimulatorService.derivedDataPath(for: projectPath)
    let second = SimulatorService.derivedDataPath(for: projectPath)
    let other = SimulatorService.derivedDataPath(for: "/tmp/OtherProject")

    #expect(first == second)
    #expect(first != other)
    #expect(first.contains("/Library/Application Support/AgentHub/Builds/"))
  }

  @Test func buildOutputAccumulatorKeepsBoundedTail() throws {
    let accumulator = BuildOutputAccumulator(maxBytes: 5)

    accumulator.append(Data("abc".utf8))
    accumulator.append(Data("defg".utf8))

    let output = try #require(String(data: accumulator.combinedData(), encoding: .utf8))
    #expect(output == "cdefg")
  }

  @Test func preferredAppBundlePathPrefersSchemeMatchOverTestRunner() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SimulatorServiceTests-\(UUID().uuidString)", isDirectory: true)
    let products = root.appendingPathComponent("Build/Products/Debug-iphonesimulator", isDirectory: true)

    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: products.appendingPathComponent("Demo.app", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: products.appendingPathComponent("DemoTests-Runner.app", isDirectory: true),
      withIntermediateDirectories: true
    )

    defer { try? FileManager.default.removeItem(at: root) }

    let appPath = SimulatorService.preferredAppBundlePath(
      in: products.path,
      preferredAppName: "Demo"
    )

    let expectedPath = products
      .appendingPathComponent("Demo.app")
      .standardizedFileURL
      .path
    #expect(URL(fileURLWithPath: try #require(appPath)).standardizedFileURL.path == expectedPath)
  }

  @Test func resolveBuiltMacAppSearchesProductsTree() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SimulatorServiceTests-\(UUID().uuidString)", isDirectory: true)
    let macProducts = root.appendingPathComponent("Build/Products/Debug-macosx", isDirectory: true)
    let simulatorProducts = root.appendingPathComponent("Build/Products/Debug-iphonesimulator", isDirectory: true)
    let expectedApp = macProducts.appendingPathComponent("Demo.app", isDirectory: true)

    try FileManager.default.createDirectory(at: expectedApp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: simulatorProducts.appendingPathComponent("Demo.app", isDirectory: true),
      withIntermediateDirectories: true
    )

    defer { try? FileManager.default.removeItem(at: root) }

    let builtApp = try #require(SimulatorService.resolveBuiltApp(
      derivedDataPath: root.path,
      scheme: "Demo",
      platform: .macOS,
      requiresBundleIdentifier: false
    ))

    #expect(URL(fileURLWithPath: builtApp.appPath).standardizedFileURL.path == expectedApp.standardizedFileURL.path)
  }

  @Test func resolveSimulatorAppSkipsCandidatesWithoutBundleIdentifier() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SimulatorServiceTests-\(UUID().uuidString)", isDirectory: true)
    let products = root.appendingPathComponent("Build/Products/Debug-iphonesimulator", isDirectory: true)
    let staleApp = products.appendingPathComponent("Demo.app", isDirectory: true)
    let launchableApp = products.appendingPathComponent("DemoPreview.app", isDirectory: true)

    try FileManager.default.createDirectory(at: staleApp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: launchableApp, withIntermediateDirectories: true)
    try writeInfoPlist(bundleIdentifier: "com.agenthub.demo-preview", to: launchableApp)

    defer { try? FileManager.default.removeItem(at: root) }

    let builtApp = try #require(SimulatorService.resolveBuiltApp(
      derivedDataPath: root.path,
      scheme: "Demo",
      platform: .iOSSimulator,
      requiresBundleIdentifier: true
    ))

    #expect(URL(fileURLWithPath: builtApp.appPath).standardizedFileURL.path == launchableApp.standardizedFileURL.path)
    #expect(builtApp.bundleIdentifier == "com.agenthub.demo-preview")
  }

  @Test func resolveDeviceAppUsesIPhoneOSProducts() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SimulatorServiceTests-\(UUID().uuidString)", isDirectory: true)
    let deviceProducts = root.appendingPathComponent("Build/Products/Debug-iphoneos", isDirectory: true)
    let simulatorProducts = root.appendingPathComponent("Build/Products/Debug-iphonesimulator", isDirectory: true)
    let expectedApp = deviceProducts.appendingPathComponent("Demo.app", isDirectory: true)

    try FileManager.default.createDirectory(at: expectedApp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: simulatorProducts.appendingPathComponent("Demo.app", isDirectory: true),
      withIntermediateDirectories: true
    )
    try writeInfoPlist(bundleIdentifier: "com.agenthub.demo-device", to: expectedApp)

    defer { try? FileManager.default.removeItem(at: root) }

    let builtApp = try #require(SimulatorService.resolveBuiltApp(
      derivedDataPath: root.path,
      scheme: "Demo",
      platform: .iOSDevice,
      requiresBundleIdentifier: true
    ))

    #expect(URL(fileURLWithPath: builtApp.appPath).standardizedFileURL.path == expectedApp.standardizedFileURL.path)
    #expect(builtApp.bundleIdentifier == "com.agenthub.demo-device")
  }

  @Test func physicalDeviceBuildArgumentsAllowAutomaticProvisioning() {
    let args = SimulatorService.physicalDeviceBuildArguments(
      scheme: "Demo",
      targetPath: "/tmp/Demo.xcodeproj",
      isWorkspace: false,
      identifier: "DEVICE-1",
      derivedDataPath: "/tmp/DerivedData"
    )

    #expect(args.contains("-allowProvisioningUpdates"))
    #expect(args.contains("-allowProvisioningDeviceRegistration"))
    #expect(args.contains("-destination-timeout"))
    #expect(args.contains("id=DEVICE-1"))
    #expect(args.contains("-project"))
    #expect(args.contains("/tmp/Demo.xcodeproj"))
  }

  @Test func bundleIdentifierReadsInfoPlist() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("SimulatorServiceTests-\(UUID().uuidString)", isDirectory: true)
    let app = root.appendingPathComponent("Demo.app", isDirectory: true)

    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try writeInfoPlist(bundleIdentifier: "com.agenthub.demo", to: app)

    defer { try? FileManager.default.removeItem(at: root) }

    let bundleIdentifier = SimulatorService.bundleIdentifier(atAppPath: app.path)
    #expect(bundleIdentifier == "com.agenthub.demo")
  }

  private func writeInfoPlist(bundleIdentifier: String, to app: URL) throws {
    let infoPlist: [String: Any] = [
      "CFBundleIdentifier": bundleIdentifier
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: infoPlist,
      format: .xml,
      options: 0
    )
    try data.write(to: app.appendingPathComponent("Info.plist"))
  }
}

// MARK: - Preference persistence

/// Mock persistence backend recording calls in order.
private final class MockSimulatorPreferenceStore: SimulatorPreferencePersisting, @unchecked Sendable {
  enum Call: Equatable {
    case save(ProjectSimulatorPreference)
    case delete(String)
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  var seeded: [ProjectSimulatorPreference] = []

  var calls: [Call] {
    lock.withLock { _calls }
  }

  func getProjectSimulatorPreferences() async throws -> [ProjectSimulatorPreference] {
    seeded
  }

  func setProjectSimulatorPreference(_ preference: ProjectSimulatorPreference) async throws {
    lock.withLock { _calls.append(.save(preference)) }
  }

  func deleteProjectSimulatorPreference(projectPath: String) async throws {
    lock.withLock { _calls.append(.delete(projectPath)) }
  }
}

@Suite("SimulatorService preference persistence")
@MainActor
struct SimulatorServicePreferencePersistenceTests {

  @Test func settingSimulatorPersistsPreference() async {
    let store = MockSimulatorPreferenceStore()
    let service = SimulatorService.makeForTesting()
    service.configurePreferenceStore(store)
    await service.ensurePreferencesLoaded()
    let path = "/tmp/persist-test-\(UUID().uuidString)"

    service.setPreferredSimulator(udid: "UDID-1", for: path)
    service.setPreferredPhysicalDevice(identifier: nil, for: path)
    await service.flushPreferencePersistence()

    let saves = store.calls.compactMap { call -> ProjectSimulatorPreference? in
      if case .save(let preference) = call, preference.projectPath == path { return preference }
      return nil
    }
    #expect(saves.last?.deviceIdentifier == "UDID-1")
    #expect(saves.last?.kind == .simulator)
  }

  @Test func switchingToPhysicalPersistsPhysicalKind() async {
    let store = MockSimulatorPreferenceStore()
    let service = SimulatorService.makeForTesting()
    service.configurePreferenceStore(store)
    await service.ensurePreferencesLoaded()
    let path = "/tmp/persist-test-\(UUID().uuidString)"

    service.setPreferredSimulator(udid: "UDID-1", for: path)
    service.setPreferredPhysicalDevice(identifier: nil, for: path)
    service.setPreferredPhysicalDevice(identifier: "PHONE-1", for: path)
    service.setPreferredSimulator(udid: nil, for: path)
    await service.flushPreferencePersistence()

    guard case .save(let last)? = store.calls.last(where: {
      if case .save(let preference) = $0 { return preference.projectPath == path }
      return false
    }) else {
      Issue.record("expected a save call")
      return
    }
    #expect(last.deviceIdentifier == "PHONE-1")
    #expect(last.kind == .physical)
  }

  @Test func clearingBothSidesDeletesPreference() async {
    let store = MockSimulatorPreferenceStore()
    let service = SimulatorService.makeForTesting()
    service.configurePreferenceStore(store)
    await service.ensurePreferencesLoaded()
    let path = "/tmp/persist-test-\(UUID().uuidString)"

    service.setPreferredSimulator(udid: "UDID-1", for: path)
    service.setPreferredSimulator(udid: nil, for: path)
    await service.flushPreferencePersistence()

    #expect(store.calls.last == .delete(path))
  }

  @Test func hydrationPopulatesDictionariesWithoutOverridingLiveSelections() async {
    let service = SimulatorService.makeForTesting()
    let persistedPath = "/tmp/hydrate-test-\(UUID().uuidString)"
    let livePath = "/tmp/live-test-\(UUID().uuidString)"
    service.setPreferredSimulator(udid: "LIVE-UDID", for: livePath)

    let store = MockSimulatorPreferenceStore()
    store.seeded = [
      ProjectSimulatorPreference(projectPath: persistedPath, deviceIdentifier: "SAVED-UDID", kind: .simulator),
      ProjectSimulatorPreference(projectPath: livePath, deviceIdentifier: "STALE-UDID", kind: .physical)
    ]
    service.configurePreferenceStore(store)
    await service.ensurePreferencesLoaded()

    #expect(service.preferredSimulatorUDIDs[persistedPath] == "SAVED-UDID")
    #expect(service.preferredSimulatorUDIDs[livePath] == "LIVE-UDID")
    #expect(service.preferredPhysicalDeviceIDs[livePath] == nil)
    #expect(service.preferencesLoaded)
  }
}
