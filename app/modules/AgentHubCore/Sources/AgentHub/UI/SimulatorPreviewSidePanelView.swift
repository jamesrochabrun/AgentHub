//
//  SimulatorPreviewSidePanelView.swift
//  AgentHub
//
//  Embedded side panel that shows a live, interactive iOS Simulator for the
//  session's project. Device lifecycle (list/boot/build & run) reuses the
//  existing `SimulatorService`; the live capture + input comes from the
//  standalone `SimulatorPreview` module. The full management sheet
//  (`SimulatorPickerView` — Mac runs, build-error forwarding) is reachable
//  from the header, replacing the deprecated per-card Simulator button.
//
//  Annotate mode pauses touch forwarding so clicks drop numbered pins; the
//  queued pins are sent to the agent as one prompt plus a pin-stamped
//  screenshot, through the same terminal-prompt path as web preview feedback.
//
//  Privacy: all capture stays in-process. Nothing is streamed off the machine
//  and no Screen Recording / Accessibility permission is requested — only the
//  simulator's own framebuffer is read. The single write to disk is the
//  pin-stamped screenshot saved to a temp file when the user explicitly sends
//  annotations. See the SimulatorPreview README.
//

import AppKit
import SimulatorPreview
import SwiftUI

struct SimulatorPreviewSidePanelView: View {
  let session: CLISession
  let projectPath: String
  let onDismiss: () -> Void
  var onSendToSession: ((String, CLISession) -> Void)? = nil

  @Environment(\.agentHub) private var agentHub

  @State private var simulatorService = SimulatorService.shared
  @State private var selectedUDID: String?
  @State private var hasLoadedDevices = false
  @State private var annotationModel = SimulatorAnnotationModel()
  @State private var showingManageSheet = false

  private var streamService: any SimulatorStreamServiceProtocol {
    agentHub?.simulatorStreamService ?? SimulatorStreamService.shared
  }

  /// The device to preview: explicit selection, else the project's preferred
  /// device, else the first booted device we can find.
  private var activeUDID: String? {
    if let selectedUDID { return selectedUDID }
    if let preferred = simulatorService.preferredSimulatorUDIDs[projectPath] { return preferred }
    return bootedDevices.first?.udid
  }

  private var bootedDevices: [SimulatorDevice] {
    simulatorService.runtimes.flatMap { $0.availableDevices }.filter { $0.isBooted }
  }

  private var availableDevices: [SimulatorDevice] {
    simulatorService.runtimes.flatMap { $0.availableDevices }
  }

  private var activeDevice: SimulatorDevice? {
    guard let activeUDID else { return nil }
    return availableDevices.first { $0.udid == activeUDID }
  }

  private var activeState: SimulatorState {
    guard let activeUDID else { return .idle }
    return simulatorService.state(for: activeUDID, projectPath: projectPath)
  }

  /// Live boot state — consults `SimulatorService.isBooted` (updated by boot /
  /// build flows) rather than the static device-list snapshot, so the preview
  /// flips to the stream as soon as the device is actually up.
  private var isActiveDeviceBooted: Bool {
    guard let activeUDID else { return false }
    return simulatorService.isBooted(udid: activeUDID)
  }

  private var isShowingLiveStream: Bool {
    isActiveDeviceBooted
  }

  /// True while a boot or build/install/launch is in flight for the active
  /// device — used to show progress instead of a (double-boot-prone) button.
  private var isActiveDevicePreparing: Bool {
    switch activeState {
    case .booting, .building, .installing, .launching:
      return true
    default:
      return false
    }
  }

  /// The OS the active device runs, e.g. "iOS 26.4".
  private var activeRuntimeName: String? {
    guard let activeUDID else { return nil }
    return simulatorService.runtimes
      .first { $0.devices.contains { $0.udid == activeUDID } }?
      .displayName
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(
      minWidth: 320, idealWidth: .infinity, maxWidth: .infinity,
      minHeight: 320, idealHeight: .infinity, maxHeight: .infinity
    )
    .task { await loadDevicesIfNeeded() }
    .onChange(of: activeUDID) { _, _ in
      annotationModel.reset()
    }
    .onChange(of: annotationModel.isAnnotating) { _, isOn in
      if isOn {
        refreshElements()
      } else {
        annotationModel.clearPending()
        annotationModel.hoveredElement = nil
      }
    }
    .sheet(isPresented: $showingManageSheet) {
      SimulatorPickerView(
        session: session,
        onDismiss: { showingManageSheet = false },
        onSendToSession: onSendToSession.map { send in
          { error in
            send("Fix this build error:\n\(error)", session)
            showingManageSheet = false
          }
        }
      )
    }
    .onKeyPress(.escape) {
      if annotationModel.isAnnotating {
        annotationModel.exitAnnotating()
        return .handled
      }
      onDismiss()
      return .handled
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "iphone.gen3")
        .foregroundStyle(Color.brandPrimary)
        .accessibilityHidden(true)

      Text("Simulator")
        .font(.headline)

      if !streamService.availability.isInteractive {
        Text("View-only")
          .font(.caption2.weight(.medium))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.secondary.opacity(0.15)))
          .help("Live touch injection is unavailable on this machine; showing a screenshot stream.")
      }

      Spacer(minLength: 12)

      devicePicker
      buildAndRunButton
      stopButton
      // Manage sheet temporarily hidden — it can drift out of sync with the
      // device picker. The code (`manageButton` + `.sheet`) is kept for when
      // it's reconciled and re-enabled.

      Button("Close", action: onDismiss)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var devicePicker: some View {
    if !availableDevices.isEmpty {
      Picker("Device", selection: Binding(
        get: { activeUDID },
        set: { newValue in
          selectedUDID = newValue
          if let newValue { simulatorService.setPreferredSimulator(udid: newValue, for: projectPath) }
        }
      )) {
        // Placeholder so the picker never renders blank when nothing is
        // selected yet (e.g. no booted/preferred device on first open).
        if activeUDID == nil {
          Text("Select Simulator")
            .tag(Optional<String>.none)
        }
        ForEach(availableDevices) { device in
          Text(device.isBooted ? "\(device.name) ●" : device.name)
            .tag(Optional(device.udid))
        }
      }
      .labelsHidden()
      .frame(maxWidth: 200)
      .accessibilityLabel("Select simulator")
    }
  }

  @ViewBuilder
  private var buildAndRunButton: some View {
    switch activeState {
    case .building, .installing, .launching, .booting:
      ProgressView()
        .controlSize(.small)
        .frame(width: 22, height: 22)
    default:
      Button(action: buildAndRun) {
        Image(systemName: "play.fill")
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .disabled(activeUDID == nil)
      .help("Build & run this project on the selected simulator")
    }
  }

  /// Shuts down the active simulator. Shown beside Build & Run; a spinner
  /// replaces it while the device is shutting down.
  @ViewBuilder
  private var stopButton: some View {
    switch activeState {
    case .shuttingDown:
      ProgressView()
        .controlSize(.small)
        .frame(width: 22, height: 22)
    default:
      Button(action: stopSimulator) {
        Image(systemName: "stop.fill")
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .disabled(!(activeDevice?.isBooted ?? false))
      .help("Shut down the simulator")
    }
  }

  private var manageButton: some View {
    Button {
      showingManageSheet = true
    } label: {
      Image(systemName: "slider.horizontal.3")
        .font(.caption)
    }
    .buttonStyle(.borderless)
    .help("Manage simulators and builds (Mac runs, build logs)")
    .accessibilityLabel("Manage simulators")
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if let activeUDID, isShowingLiveStream {
      streamContent(udid: activeUDID)
    } else if simulatorService.isLoadingDevices && !hasLoadedDevices {
      loadingState
    } else if availableDevices.isEmpty {
      emptyState
    } else {
      notBootedState
    }
  }

  private func streamContent(udid: String) -> some View {
    let streamSession = streamService.session(forDeviceUDID: udid)
    // The chrome sizes the inner ZStack to the framebuffer's exact aspect
    // ratio, so the overlay's coordinate mapping inside it is letterbox-free.
    return SimulatorDeviceChromeView(
      contentPixelSize: annotationModel.contentPixelSize,
      deviceTypeIdentifier: activeDevice?.deviceTypeIdentifier
    ) {
      ZStack {
        SimulatorStreamView(
          session: streamSession,
          isInteractive: streamService.availability.isInteractive && !annotationModel.isAnnotating
        )

        if annotationModel.isAnnotating || !annotationModel.annotations.isEmpty {
          SimulatorAnnotationOverlayView(model: annotationModel)
            .allowsHitTesting(annotationModel.isAnnotating)
        }
      }
    } topAccessory: {
      SimulatorDeviceToolbarView(
        deviceName: activeDevice?.name ?? "Simulator",
        runtimeName: activeRuntimeName,
        isInteractive: streamService.availability.isInteractive,
        showsAnnotate: onSendToSession != nil,
        isAnnotating: annotationModel.isAnnotating,
        isFetchingElements: annotationModel.isFetchingElements,
        onHome: goHome,
        onToggleAnnotate: {
          annotationModel.isAnnotating
            ? annotationModel.exitAnnotating()
            : (annotationModel.isAnnotating = true)
        },
        onRefreshElements: refreshElements
      )
    }
    .id(udid)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: udid) { observeStreamState(of: streamSession) }
    .safeAreaInset(edge: .bottom) {
      if !annotationModel.annotations.isEmpty {
        SimulatorAnnotationTrayView(
          annotations: annotationModel.annotations,
          isSending: annotationModel.isSending,
          onRemove: { annotationModel.remove(id: $0) },
          onSendAll: sendAnnotations,
          onClearAll: { annotationModel.clearAnnotations() }
        )
        .padding(12)
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView()
      Text("Loading simulators…")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No Simulators",
      systemImage: "iphone.slash",
      description: Text("No available iOS simulators were found on this machine.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var notBootedState: some View {
    VStack(spacing: 12) {
      Image(systemName: "iphone.gen3")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)

      if isActiveDevicePreparing {
        // A boot/build is already in flight — show progress instead of a Boot
        // button so the user can't kick off a second `simctl boot` (→ 149).
        Text(preparingLabel)
          .font(.subheadline)
        ProgressView()
          .controlSize(.small)
      } else {
        Text(activeDevice.map { "\($0.name) is not booted" } ?? "Select a simulator")
          .font(.subheadline)
        if let activeUDID {
          Button {
            Task { await simulatorService.bootDevice(udid: activeUDID) }
          } label: {
            Label("Boot & Preview", systemImage: "power")
          }
          .buttonStyle(.borderedProminent)
        }
      }

      if case .failed(let message) = activeState {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(3)
          .padding(.horizontal)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var preparingLabel: String {
    switch activeState {
    case .building: return "Building…"
    case .installing: return "Installing…"
    case .launching: return "Launching…"
    default: return "Booting…"
    }
  }

  // MARK: - Actions

  private func loadDevicesIfNeeded() async {
    guard !hasLoadedDevices else { return }
    await simulatorService.listDevices()
    hasLoadedDevices = true
  }

  private func buildAndRun() {
    guard let activeUDID else { return }
    Task {
      // Boot first so the preview switches to the live stream immediately,
      // before the build finishes installing/launching the app. `bootDevice`
      // is idempotent and refreshes the device list; the build's own boot is
      // then a no-op.
      if !simulatorService.isBooted(udid: activeUDID) {
        await simulatorService.bootDevice(udid: activeUDID)
      }
      await simulatorService.buildAndRunOnSimulator(udid: activeUDID, projectPath: projectPath)
    }
  }

  private func stopSimulator() {
    guard let activeUDID else { return }
    Task { await simulatorService.shutdownDevice(udid: activeUDID) }
  }

  /// Home-button devices (~16:9 screens) take a button press; edge-to-edge
  /// devices need the swipe-up-from-bottom gesture instead.
  private func goHome() {
    guard let activeUDID else { return }
    let streamSession = streamService.session(forDeviceUDID: activeUDID)
    let size = annotationModel.contentPixelSize
    let aspect = size.width > 0 && size.height > 0
      ? max(size.width, size.height) / min(size.width, size.height)
      : 2.16
    streamSession.sendButton(aspect > 1.5 && aspect < 1.85 ? .home : .swipeHome)
  }

  /// Keeps the annotation model's framebuffer size current so pins can map
  /// between view space and device pixels. The render view consumes `onFrame`;
  /// this panel is the sole consumer of `onStateChange`.
  private func observeStreamState(of streamSession: any SimulatorStreamSessionProtocol) {
    let model = annotationModel
    let apply: (SimulatorStreamSessionState) -> Void = { state in
      if case .streaming(let width, let height) = state {
        model.contentPixelSize = CGSize(width: width, height: height)
      }
    }
    apply(streamSession.state)
    streamSession.onStateChange = { state in
      Task { @MainActor in apply(state) }
    }
  }

  /// Reads the frontmost app's accessibility tree so the overlay can show
  /// element frames and bind pins to elements. Failure is non-fatal — the
  /// overlay falls back to positional pins.
  private func refreshElements() {
    guard let udid = activeUDID else { return }
    let model = annotationModel
    model.isFetchingElements = true
    Task {
      let tree = try? await SimulatorAXInspector.shared.fetchFrontmostTree(
        udid: udid, developerDir: XcodeDeveloperDirectory.resolved)
      model.axTree = tree
      model.isFetchingElements = false
    }
  }

  private func sendAnnotations() {
    guard let onSendToSession,
          let udid = activeUDID,
          !annotationModel.annotations.isEmpty,
          !annotationModel.isSending
    else { return }

    let annotations = annotationModel.annotations
    let deviceName = activeDevice?.name
    let pixelSize = annotationModel.hasContentSize ? annotationModel.contentPixelSize : nil
    let screenPointSize = annotationModel.screenPointSize
    annotationModel.isSending = true

    Task {
      // Best-effort: the prompt still goes out without the screenshot.
      let screenshotURL = await SimulatorScreenshotCapture.writeAnnotatedScreenshot(
        udid: udid, annotations: annotations)
      let prompt = SimulatorAnnotationPromptBuilder.prompt(
        annotations: annotations,
        deviceName: deviceName,
        screenPointSize: screenPointSize,
        screenshotPixelSize: pixelSize,
        screenshotPath: screenshotURL?.path
      )
      annotationModel.isSending = false
      onSendToSession(prompt, session)
      annotationModel.clearAnnotations()
      annotationModel.exitAnnotating()
    }
  }
}
