//
//  SimulatorPreviewSidePanelView.swift
//  AgentHub
//
//  Embedded side panel that shows a live, interactive iOS Simulator for the
//  session's project. Device lifecycle (list/boot/build & run) reuses the
//  existing `SimulatorService`; the live capture + input comes from the
//  standalone `SimulatorPreview` module. The legacy management sheet
//  (`SimulatorPickerView` — Mac runs, build-error forwarding) is kept wired
//  but hidden while the side panel remains the single entry point.
//
//  Annotate mode pauses tap forwarding so clicks drop numbered pins; drag
//  gestures still forward as simulator touches so scrollable app content can
//  be reached. Queued pins are sent to the agent as one prompt plus a pin-stamped
//  screenshot, through the same terminal-prompt path as web preview feedback.
//
//  Privacy: all capture stays in-process. Nothing is streamed off the machine
//  and no Screen Recording / Accessibility permission is requested — only the
//  simulator's own framebuffer is read. The single write to disk is the
//  pin-stamped screenshot saved to a temp file when the user explicitly sends
//  annotations. See the SimulatorPreview README.
//

import AppKit
import AgentHubCLIKit
import SimulatorPreview
import SwiftUI

/// Which surface the panel shows for a booted device: the live device
/// mirror, or the app's SwiftUI previews when that feature is enabled.
enum SimulatorPanelDisplayMode: String, Hashable {
  case live
  case previews
}

struct SimulatorPreviewSidePanelView: View {
  let session: CLISession
  let projectPath: String
  let providerKind: SessionProviderKind
  let onDismiss: () -> Void
  var onSendToSession: ((String, CLISession) -> Void)? = nil
  /// File open in the session's editor pane — its previews join the
  /// spotlight alongside changed files.
  var openEditorFilePath: String? = nil

  @Environment(\.agentHub) private var agentHub

  @State private var simulatorService = SimulatorService.shared
  @State private var selectedUDID: String?
  @State private var hasLoadedDevices = false
  @State private var annotationModel = SimulatorAnnotationModel()
  @State private var isAnnotationTrayExpanded = false
  @State private var showingManageSheet = false
  @State private var displayMode: SimulatorPanelDisplayMode = .live
  @State private var hotReload = SimulatorHotReloadController()
  @State private var annotationRefreshTask: Task<Void, Never>?
  @State private var recordingState: SimulatorRecordingPanelState = .idle
  @State private var lastRecordingResult: SimulatorRecordingResult?
  @State private var recordingAuditIssue = ""
  @State private var recordingFailureDismissTask: Task<Void, Never>?
  @State private var streamRefreshGeneration = 0
  /// The failure message the user explicitly dismissed; the banner stays
  /// hidden for that exact message but reappears for any new/different error.
  @State private var dismissedFailureMessage: String?

  private let simulatorContextStore = SimulatorSessionContextStore()
  private let simulatorRecordingService = SimulatorRecordingService.shared

  @AppStorage(AgentHubDefaults.simulatorPreviewsEnabled)
  private var simulatorPreviewsEnabled: Bool = true

  private var streamService: any SimulatorStreamServiceProtocol {
    agentHub?.simulatorStreamService ?? SimulatorStreamService.shared
  }

  private var simulatorContextProvider: WorktreeLaunchProvider? {
    WorktreeLaunchProvider(commandLineValue: providerKind.rawValue)
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

  private var effectiveDisplayMode: SimulatorPanelDisplayMode {
    simulatorPreviewsEnabled ? displayMode : .live
  }

  /// The collapsed tray is shallow enough to dodge visually without changing
  /// layout. Expanded comments stay overlay-only, so the simulator never
  /// resizes as the tray opens.
  private var liveStreamVerticalOffset: CGFloat {
    guard effectiveDisplayMode == .live,
          !annotationModel.annotations.isEmpty,
          !isAnnotationTrayExpanded
    else {
      return 0
    }
    return -56
  }

  /// True while an injection or fallback rebuild is mid-flight — preview
  /// cards pause rendering so they don't race the code swap.
  private var isReloadInFlight: Bool {
    switch hotReload.monitor.phase {
    case .reloading, .rebuilding:
      return true
    default:
      return false
    }
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

  private var activeFailureMessage: String? {
    if case .failed(let message) = activeState {
      return message
    }
    return nil
  }

  /// The failure message to actually render — `nil` once the user dismisses
  /// the current one (until a different failure arrives).
  private var visibleFailureMessage: String? {
    guard let activeFailureMessage, activeFailureMessage != dismissedFailureMessage else {
      return nil
    }
    return activeFailureMessage
  }

  private var simulatorContextSignature: String {
    [
      simulatorContextProvider?.commandLineValue ?? "unknown",
      session.id,
      projectPath,
      activeUDID ?? "",
      activeDevice?.name ?? "",
      activeRuntimeName ?? "",
      isActiveDeviceBooted ? "booted" : "not-booted",
      effectiveDisplayMode.rawValue,
    ].joined(separator: "|")
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
    .task {
      await loadDevicesIfNeeded()
      if simulatorPreviewsEnabled {
        hotReload.warmUp()
      }
      hotReload.setPreviewObservationEnabled(simulatorPreviewsEnabled, projectPath: projectPath)
    }
    .onDisappear {
      cancelAnnotationElementRefresh()
      hotReload.stopTracking()
      hotReload.sessionDidStop()
      removeSimulatorContext()
      stopRecordingOnPanelClose()
      recordingFailureDismissTask?.cancel()
    }
    .task(id: simulatorContextSignature) {
      persistSimulatorContext()
    }
    .onChange(of: activeUDID) { _, _ in
      cancelAnnotationElementRefresh()
      annotationModel.reset()
      isAnnotationTrayExpanded = false
      hotReload.sessionDidStop()
      if effectiveDisplayMode == .previews { autoArmPreviewsIfNeeded() }
    }
    .onChange(of: displayMode) { _, mode in
      if simulatorPreviewsEnabled, mode == .previews { autoArmPreviewsIfNeeded() }
    }
    .onChange(of: simulatorPreviewsEnabled) { _, isEnabled in
      hotReload.setPreviewObservationEnabled(isEnabled, projectPath: projectPath)
      if isEnabled {
        hotReload.warmUp()
        if displayMode == .previews {
          autoArmPreviewsIfNeeded()
        }
      } else {
        displayMode = .live
      }
    }
    .onChange(of: openEditorFilePath) { _, _ in
      if effectiveDisplayMode == .previews { autoArmPreviewsIfNeeded() }
    }
    .onChange(of: hotReload.changedSourceFiles) { _, _ in
      if effectiveDisplayMode == .previews { autoArmPreviewsIfNeeded() }
    }
    .onChange(of: annotationModel.isAnnotating) { _, isOn in
      if isOn {
        refreshElements()
      } else {
        annotationModel.clearPending()
        annotationModel.hoveredElement = nil
      }
    }
    .onChange(of: annotationModel.annotations.isEmpty) { _, isEmpty in
      if isEmpty {
        isAnnotationTrayExpanded = false
      }
    }
    .sheet(isPresented: $showingManageSheet) {
      SimulatorPickerView(
        session: session,
        onDismiss: { showingManageSheet = false },
        onSendToSession: onSendToSession.map { send in
          { error in
            send(SimulatorBuildErrorPromptBuilder.prompt(for: error), session)
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
      return .handled
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      if activeUDID != nil, simulatorPreviewsEnabled {
        displayModePicker
      }

      if !streamService.availability.isInteractive {
        viewOnlyBadge
      }

      HotReloadStatusPillView(
        phase: hotReload.monitor.phase,
        warning: hotReload.monitor.lastWarning
      )

      Spacer(minLength: 8)

      devicePicker
      // Manage sheet temporarily hidden — it can drift out of sync with the
      // device picker. The code (`manageButton` + `.sheet`) is kept for when
      // it's reconciled and re-enabled.

      closeButton
    }
    .padding(.horizontal, 12)
    .frame(height: AgentHubLayout.topBarHeight)
  }

  private var viewOnlyBadge: some View {
    Text("View-only")
      .font(.caption.weight(.medium))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.secondary.opacity(0.15)))
      .help("Live touch injection is unavailable on this machine; showing a screenshot stream.")
  }

  /// Live mirror ↔ Previews. The Previews option is only visible when the
  /// simulator previews setting is enabled.
  private var displayModePicker: some View {
    CompactPillSegmentedControl(
      selection: $displayMode,
      items: [
        CompactPillSegmentedControlItem(
          value: .live,
          title: "Live",
          helpText: "Show the live simulator"
        ),
        CompactPillSegmentedControlItem(
          value: .previews,
          title: "Previews",
          helpText: "Show SwiftUI previews"
        ),
      ],
      selectedColor: Color.brandSecondary,
      accessibilityLabel: "Panel display mode"
    )
  }

  @ViewBuilder
  private var devicePicker: some View {
    if !availableDevices.isEmpty {
      Menu {
        ForEach(availableDevices) { device in
          Button {
            selectDevice(udid: device.udid)
          } label: {
            HStack {
              Text(device.name)
              if device.isBooted {
                Text("Running")
              }
              if activeUDID == device.udid {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      } label: {
        HStack(spacing: 6) {
          Text(activeDevice?.name ?? "Select Simulator")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.16), lineWidth: 1))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize(horizontal: true, vertical: false)
      .layoutPriority(2)
      .accessibilityLabel("Select simulator")
    }
  }

  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.caption.weight(.semibold))
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.secondary.opacity(0.12)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help("Close simulator preview")
    .accessibilityLabel("Close simulator preview")
  }

  private var isBuildAndRunInProgress: Bool {
    switch activeState {
    case .building, .installing, .launching, .booting: return true
    default: return false
    }
  }

  private var isShutdownInProgress: Bool {
    if case .shuttingDown = activeState { return true }
    return false
  }

  private var floatingRunControls: some View {
    VStack(spacing: 8) {
      SimulatorFloatingActionButton(
        systemImage: "play.fill",
        tint: Color.brandPrimary,
        isDisabled: activeUDID == nil || isBuildAndRunInProgress,
        isWorking: isBuildAndRunInProgress,
        help: "Build & run this project on the selected simulator",
        accessibilityLabel: "Build and run",
        action: buildAndRun
      )

      SimulatorFloatingActionButton(
        systemImage: "stop.fill",
        tint: .red,
        isDisabled: !isActiveDeviceBooted || isShutdownInProgress,
        isWorking: isShutdownInProgress,
        help: "Shut down the simulator",
        accessibilityLabel: "Shut down simulator",
        action: stopSimulator
      )
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
    contentBody
      .overlay(alignment: .bottom) {
        recordingStatusOverlay
      }
      .overlay(alignment: .bottomTrailing) {
        bottomTrailingControlsOverlay
      }
      .overlay(alignment: .top) {
        simulatorFailureBannerOverlay
      }
      .overlay(alignment: .topTrailing) {
        if activeUDID != nil {
          floatingRunControls
            .padding(14)
        }
      }
      .animation(
        .spring(response: 0.34, dampingFraction: 0.85),
        value: annotationModel.annotations.isEmpty
      )
  }

  @ViewBuilder
  private var recordingStatusOverlay: some View {
    if recordingState != .idle || lastRecordingResult != nil {
      HStack(alignment: .bottom, spacing: 0) {
        recordingOverlay
          .allowsHitTesting(recordingOverlayAllowsHitTesting)

        Spacer(minLength: 58)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }
  }

  private var bottomTrailingControlsOverlay: some View {
    VStack(alignment: .trailing, spacing: 10) {
      if activeUDID != nil {
        floatingRecordingControl
          .padding(.trailing, 14)
          .padding(.bottom, annotationModel.annotations.isEmpty ? 14 : 0)
      }

      annotationCommentsOverlay
    }
  }

  private var floatingRecordingControl: some View {
    SimulatorFloatingActionButton(
      systemImage: recordingButtonSystemImage,
      tint: .red,
      isDisabled: isRecordingButtonDisabled,
      isWorking: recordingState.isBusy,
      help: recordingButtonHelp,
      accessibilityLabel: recordingButtonAccessibilityLabel,
      action: toggleRecording
    )
  }

  @ViewBuilder
  private var contentBody: some View {
    if let activeUDID, isShowingLiveStream {
      // Both surfaces stay mounted so flipping tabs doesn't tear down and
      // re-attach the live stream (a visible reconnect).
      ZStack {
        streamContent(udid: activeUDID)
          .opacity(effectiveDisplayMode == .live ? 1 : 0)
          .allowsHitTesting(effectiveDisplayMode == .live)
          .offset(y: liveStreamVerticalOffset)
          .id("\(activeUDID)-\(streamRefreshGeneration)")
          .animation(
            .spring(response: 0.34, dampingFraction: 0.85),
            value: liveStreamVerticalOffset
          )

        if effectiveDisplayMode == .previews {
          spotlightView
            .background(Color(nsColor: .windowBackgroundColor))
        }
      }
    } else if effectiveDisplayMode == .previews, activeUDID != nil {
      // Cold start straight into Previews: the spotlight's states guide the
      // bootstrap, and the tab switch auto-runs the app when a file is open.
      spotlightView
    } else if simulatorService.isLoadingDevices && !hasLoadedDevices {
      loadingState
    } else if availableDevices.isEmpty {
      emptyState
    } else {
      notBootedState
    }
  }

  private var spotlightView: some View {
    SimulatorPreviewSpotlightView(
      client: hotReload.previewClient,
      reloadGeneration: hotReload.monitor.reloadGeneration + hotReload.previewHostGeneration,
      changedFiles: hotReload.changedSourceFiles,
      openFileName: openEditorFilePath.map {
        ($0 as NSString).lastPathComponent
      },
      isReloadInFlight: isReloadInFlight,
      onLaunchPreviews: launchPreviews,
      isPreviewHostExpected: simulatorPreviewsEnabled
        && hotReload.activePlan?.configuration.enablePreviews == true,
      connectedDeviceName: hotReload.activePlan != nil
        ? activeDevice?.name : nil
    )
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

        // Pins/overlay show only while annotating. Outside annotate mode the
        // app is interacted with directly, and keeping pins anchored would mean
        // polling the accessibility tree during normal use — so they hide here
        // and reappear (freshly positioned) when annotate mode is re-entered.
        // The annotation list stays reachable via the comments tray.
        if annotationModel.isAnnotating {
          SimulatorAnnotationOverlayView(
            model: annotationModel,
            onForwardTouch: { phase, location, viewSize in
              forwardAnnotationTouch(
                phase: phase,
                location: location,
                viewSize: viewSize,
                streamSession: streamSession
              )
            }
          )
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
        onRefreshElements: { refreshElements() }
      )
    }
    .id(udid)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: udid) { observeStreamState(of: streamSession) }
  }

  @ViewBuilder
  private var annotationCommentsOverlay: some View {
    if effectiveDisplayMode == .live, !annotationModel.annotations.isEmpty {
      SimulatorAnnotationTrayView(
        annotations: annotationModel.annotations,
        providerKind: providerKind,
        isSending: annotationModel.isSending,
        isExpanded: $isAnnotationTrayExpanded,
        onRemove: { annotationModel.remove(id: $0) },
        onUpdateText: { annotationModel.updateText(id: $0, text: $1) },
        onSendAll: sendAnnotations,
        onClearAll: { annotationModel.clearAnnotations() }
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  @ViewBuilder
  private var simulatorFailureBannerOverlay: some View {
    if let visibleFailureMessage {
      HStack(alignment: .top, spacing: 0) {
        SimulatorBuildErrorBanner(
          message: visibleFailureMessage,
          providerKind: providerKind,
          canSend: onSendToSession != nil,
          onSend: { sendBuildError(visibleFailureMessage) },
          onDismiss: { dismissFailureBanner(visibleFailureMessage) }
        )
        .frame(maxWidth: 520, alignment: .leading)

        Spacer(minLength: 52)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .transition(.move(edge: .top).combined(with: .opacity))
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
        Text(activeDevice.map { "\($0.name) is not running" } ?? "Select a simulator")
          .font(.subheadline)
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

  private func selectDevice(udid: String) {
    selectedUDID = udid
    simulatorService.setPreferredSimulator(udid: udid, for: projectPath)
  }

  private func persistSimulatorContext() {
    guard let activeUDID else {
      removeSimulatorContext()
      return
    }

    let context = SimulatorSessionContext(
      provider: simulatorContextProvider,
      sessionId: session.id.isEmpty ? nil : session.id,
      projectPath: projectPath,
      udid: activeUDID,
      deviceName: activeDevice?.name,
      runtimeName: activeRuntimeName,
      isBooted: isActiveDeviceBooted,
      displayMode: effectiveDisplayMode.rawValue,
      panelVisible: true
    )
    try? simulatorContextStore.write(context)
  }

  private func removeSimulatorContext() {
    try? simulatorContextStore.remove(
      provider: simulatorContextProvider,
      sessionId: session.id.isEmpty ? nil : session.id,
      projectPath: projectPath
    )
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
      // Arms hot reload, plus the preview host when that setting is enabled,
      // once the support dylibs are cached. First use builds them in the
      // background and this launch proceeds plain — the pill reports it
      // honestly.
      let plan = await hotReload.preparePlan(
        udid: activeUDID,
        projectPath: projectPath,
        enableInjection: true,
        enablePreviews: simulatorPreviewsEnabled
      )
      let success = await simulatorService.buildAndRunOnSimulator(
        udid: activeUDID, projectPath: projectPath, hotReload: plan
      )
      if success, let plan {
        hotReload.sessionDidLaunch(
          udid: activeUDID, projectPath: projectPath, plan: plan
        )
      }
    }
  }

  private func stopSimulator() {
    guard let activeUDID else { return }
    hotReload.sessionDidStop()
    Task { await simulatorService.shutdownDevice(udid: activeUDID) }
  }

  private var recordingButtonSystemImage: String {
    switch recordingState {
    case .recording:
      return "stop.fill"
    case .idle, .starting, .stopping, .failed:
      return "record.circle"
    }
  }

  private var recordingButtonHelp: String {
    recordingState.isRecording
      ? "Stop recording simulator video"
      : "Record simulator video"
  }

  private var recordingButtonAccessibilityLabel: String {
    recordingState.isRecording
      ? "Stop simulator recording"
      : "Start simulator recording"
  }

  private var isRecordingButtonDisabled: Bool {
    switch recordingState {
    case .starting, .stopping:
      return true
    case .recording:
      return false
    case .idle, .failed:
      return activeUDID == nil || !isActiveDeviceBooted
    }
  }

  private var recordingOverlayAllowsHitTesting: Bool {
    switch recordingState {
    case .starting, .stopping:
      return false
    case .recording:
      return true
    case .failed:
      return true
    case .idle:
      return lastRecordingResult != nil
    }
  }

  @ViewBuilder
  private var recordingOverlay: some View {
    if recordingState != .idle || lastRecordingResult != nil {
      SimulatorRecordingOverlayView(
        state: recordingState,
        lastRecording: lastRecordingResult,
        auditIssue: $recordingAuditIssue,
        canSendToAgent: onSendToSession != nil,
        onSendToAgent: sendRecordingAudit,
        onReveal: revealRecording,
        onDiscard: discardRecordingOverlay,
        onDismiss: dismissRecordingOverlay
      )
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private func toggleRecording() {
    if recordingState.isRecording {
      stopRecording()
    } else {
      startRecording()
    }
  }

  private func startRecording() {
    guard let activeUDID else { return }
    recordingFailureDismissTask?.cancel()
    lastRecordingResult = nil
    recordingAuditIssue = ""
    recordingState = .starting

    Task {
      do {
        let started = try await simulatorRecordingService.startRecording(udid: activeUDID)
        recordingState = .recording(started)
        refreshLiveStreamAfterRecordingEvent(udid: activeUDID)
      } catch {
        presentRecordingFailure(error.localizedDescription)
      }
    }
  }

  private func stopRecording() {
    guard let recording = recordingState.activeRecording else { return }
    recordingState = .stopping(recording)

    Task {
      do {
        let result = try await simulatorRecordingService.stopRecording(udid: recording.udid)
        refreshLiveStreamAfterRecordingEvent(udid: recording.udid)
        if result.isUsable {
          recordingAuditIssue = ""
          lastRecordingResult = result
          recordingState = .idle
        } else {
          try? SimulatorRecordingService.deleteRecordingFile(at: result.outputPath)
          lastRecordingResult = nil
          recordingAuditIssue = ""
          presentRecordingFailure(result.validationError ?? "Recording did not finalize. Try recording again.")
        }
      } catch {
        refreshLiveStreamAfterRecordingEvent(udid: recording.udid)
        presentRecordingFailure(error.localizedDescription)
      }
    }
  }

  private func stopRecordingOnPanelClose() {
    guard let recording = recordingState.activeRecording else { return }
    Task {
      _ = try? await simulatorRecordingService.stopRecording(udid: recording.udid)
      refreshLiveStreamAfterRecordingEvent(udid: recording.udid)
    }
  }

  private func refreshLiveStreamAfterRecordingEvent(udid: String) {
    guard effectiveDisplayMode == .live else { return }
    streamService.discardSession(forDeviceUDID: udid)
    streamRefreshGeneration += 1
  }

  private func sendRecordingAudit(_ recording: SimulatorRecordingResult, issue: String) {
    let trimmedIssue = issue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let onSendToSession, recording.isUsable, !trimmedIssue.isEmpty else { return }
    let prompt = SimulatorRecordingPromptBuilder.prompt(
      for: recording,
      deviceName: activeDevice?.name,
      issue: trimmedIssue
    )
    onSendToSession(prompt, session)
    recordingAuditIssue = ""
  }

  private func revealRecording(_ recording: SimulatorRecordingResult) {
    NSWorkspace.shared.activateFileViewerSelecting([
      URL(fileURLWithPath: recording.outputPath),
    ])
  }

  private func dismissRecordingOverlay() {
    recordingFailureDismissTask?.cancel()
    recordingFailureDismissTask = nil
    lastRecordingResult = nil
    recordingAuditIssue = ""
    if case .failed = recordingState {
      recordingState = .idle
    }
  }

  private func discardRecordingOverlay() {
    recordingFailureDismissTask?.cancel()
    recordingFailureDismissTask = nil

    if let recording = recordingState.activeRecording {
      recordingState = .stopping(recording)
      Task {
        do {
          _ = try await simulatorRecordingService.discardRecording(udid: recording.udid)
        } catch {
          AppLogger.simulator.error("Failed to discard simulator recording: \(error.localizedDescription)")
          try? SimulatorRecordingService.deleteRecordingFile(at: recording.outputPath)
        }
        refreshLiveStreamAfterRecordingEvent(udid: recording.udid)
        lastRecordingResult = nil
        recordingAuditIssue = ""
        recordingState = .idle
      }
      return
    }

    if let recording = lastRecordingResult {
      do {
        try SimulatorRecordingService.deleteRecordingFile(at: recording.outputPath)
      } catch {
        AppLogger.simulator.error("Failed to delete simulator recording: \(error.localizedDescription)")
      }
    }

    lastRecordingResult = nil
    recordingAuditIssue = ""
    if case .failed = recordingState {
      recordingState = .idle
    }
  }

  private func presentRecordingFailure(_ message: String) {
    recordingFailureDismissTask?.cancel()
    lastRecordingResult = nil
    recordingAuditIssue = ""
    recordingState = .failed(message)
    recordingFailureDismissTask = Task {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        if case .failed(let currentMessage) = recordingState, currentMessage == message {
          recordingState = .idle
        }
        recordingFailureDismissTask = nil
      }
    }
  }

  private func sendBuildError(_ error: String) {
    guard let onSendToSession else { return }
    onSendToSession(SimulatorBuildErrorPromptBuilder.prompt(for: error), session)
  }

  private func dismissFailureBanner(_ message: String) {
    withAnimation(.easeInOut(duration: 0.2)) {
      dismissedFailureMessage = message
    }
  }

  /// Bootstraps the Previews tab without a manual play press: when there's
  /// something to show (a Swift file open or changed files) and the app
  /// isn't armed, hit the play flow programmatically — full Build & Run on
  /// a cold device, the ~1s relaunch when the app is already running.
  private func autoArmPreviewsIfNeeded() {
    guard simulatorPreviewsEnabled else { return }
    guard activeUDID != nil, !isActiveDevicePreparing else { return }
    let hasSomethingToShow =
      openEditorFilePath?.hasSuffix(".swift") == true
      || !hotReload.changedSourceFiles.isEmpty
    guard hasSomethingToShow else { return }

    if !isActiveDeviceBooted {
      buildAndRun()
    } else if hotReload.activePlan == nil {
      enablePreviews()
    }
  }

  /// Self-heal for the Previews tab: relaunches the already-built app with
  /// the support dylibs inserted (~1s, no rebuild). The host can only exist
  /// in launches AgentHub armed, so an app started any other way needs this
  /// one-time relaunch.
  private func launchPreviews() {
    guard simulatorPreviewsEnabled else { return }
    if isActiveDeviceBooted {
      enablePreviews()
    } else {
      buildAndRun()
    }
  }

  private func enablePreviews() {
    guard simulatorPreviewsEnabled else { return }
    guard let activeUDID, isActiveDeviceBooted else { return }
    Task {
      let plan = await hotReload.preparePlan(
        udid: activeUDID,
        projectPath: projectPath,
        enableInjection: true,
        enablePreviews: true
      )
      guard let plan else { return } // support build in progress — pill reports it
      let success = await simulatorService.relaunchWithHotReload(
        udid: activeUDID, projectPath: projectPath, hotReload: plan
      )
      if success {
        hotReload.sessionDidLaunch(
          udid: activeUDID, projectPath: projectPath, plan: plan
        )
      } else {
        // No resolvable built app — the full pipeline is the only path.
        buildAndRun()
      }
    }
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

  private func forwardAnnotationTouch(
    phase: SimulatorTouchPhase,
    location: CGPoint,
    viewSize: CGSize,
    streamSession: any SimulatorStreamSessionProtocol
  ) -> Bool {
    guard streamService.availability.isInteractive, annotationModel.hasContentSize else {
      return false
    }

    let normalized: CGPoint?
    switch phase {
    case .began:
      normalized = SimulatorPointMapper.normalizedPoint(
        viewPoint: location,
        contentSize: annotationModel.contentPixelSize,
        viewSize: viewSize
      )
    case .moved, .ended:
      normalized = SimulatorPointMapper.clampedNormalizedPoint(
        viewPoint: location,
        contentSize: annotationModel.contentPixelSize,
        viewSize: viewSize
      )
    }
    guard let normalized else { return false }

    streamSession.sendTouch(
      phase: phase,
      normalizedX: normalized.x,
      normalizedY: normalized.y
    )
    switch phase {
    case .began:
      break
    case .moved:
      // Re-read element frames mid-drag so element-bound pins track the
      // scrolling content live instead of snapping only after release.
      liveAnnotationRefreshIfIdle()
    case .ended:
      scheduleAnnotationElementRefresh()
    }
    return true
  }

  /// Fires an element re-read during an active scroll. Self-throttling: it
  /// skips while a fetch is already in flight, so refreshes run no faster than
  /// the accessibility bridge can answer them — cheap enough to call per touch
  /// move without flooding the bridge.
  private func liveAnnotationRefreshIfIdle() {
    guard annotationModel.isAnnotating, !annotationModel.isRefreshInFlight else { return }
    refreshElements(showsSpinner: false)
  }

  /// Catches the post-scroll resting position, including momentum
  /// deceleration, with a few spaced re-reads rather than a single snapshot.
  private func scheduleAnnotationElementRefresh() {
    guard annotationModel.isAnnotating else { return }
    annotationRefreshTask?.cancel()
    annotationRefreshTask = Task { @MainActor in
      for delay in [UInt64(120_000_000), 350_000_000, 700_000_000] {
        try? await Task.sleep(nanoseconds: delay)
        guard !Task.isCancelled, annotationModel.isAnnotating else { return }
        refreshElements(showsSpinner: false)
      }
    }
  }

  private func cancelAnnotationElementRefresh() {
    annotationRefreshTask?.cancel()
    annotationRefreshTask = nil
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
  ///
  /// `showsSpinner` drives the toolbar's "fetching" indicator: true for
  /// user-initiated reads, false for the silent mid-scroll re-reads so the
  /// spinner doesn't flicker during a drag. `isRefreshInFlight` dedups
  /// overlapping reads regardless of caller.
  private func refreshElements(showsSpinner: Bool = true) {
    guard let udid = activeUDID else { return }
    let model = annotationModel
    guard !model.isRefreshInFlight else { return }
    model.isRefreshInFlight = true
    if showsSpinner { model.isFetchingElements = true }
    Task {
      let tree = try? await SimulatorAXInspector.shared.fetchFrontmostTree(
        udid: udid, developerDir: XcodeDeveloperDirectory.resolved
      )
      model.axTree = tree
      model.isRefreshInFlight = false
      model.isFetchingElements = false
    }
  }

  private func sendAnnotations() {
    guard let onSendToSession,
          let udid = activeUDID,
          !annotationModel.annotations.isEmpty,
          annotationModel.annotations.allSatisfy({
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          }),
          !annotationModel.isSending
    else { return }

    let annotations = annotationModel.annotations
    let screenshotAnnotations = annotations.map { annotation in
      // Stamp the pin at its current resolved position; if its element is no
      // longer resolvable, fall back to the original drop coordinates.
      let point = SimulatorAnnotationPinLocator.placement(
        for: annotation,
        in: annotationModel.axTree
      )?.viewportNormalizedPoint
        ?? CGPoint(x: annotation.normalizedX, y: annotation.normalizedY)
      return SimulatorAnnotation(
        id: annotation.id,
        normalizedX: point.x,
        normalizedY: point.y,
        text: annotation.text,
        target: annotation.target
      )
    }
    let deviceName = activeDevice?.name
    let pixelSize = annotationModel.hasContentSize ? annotationModel.contentPixelSize : nil
    let screenPointSize = annotationModel.screenPointSize
    annotationModel.isSending = true

    Task {
      // Best-effort: the prompt still goes out without the screenshot.
      let screenshotURL = await SimulatorScreenshotCapture.writeAnnotatedScreenshot(
        udid: udid, annotations: screenshotAnnotations
      )
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

private struct SimulatorFloatingActionButton: View {
  let systemImage: String
  let tint: Color
  let isDisabled: Bool
  let isWorking: Bool
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var foregroundColor: Color {
    isDisabled ? .secondary : tint
  }

  private var borderColor: Color {
    colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08)
  }

  var body: some View {
    Group {
      if isWorking {
        ProgressView()
          .controlSize(.small)
          .frame(width: 38, height: 38)
          .background(buttonBackground)
      } else {
        Button(action: action) {
          Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: 38, height: 38)
            .background(buttonBackground)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
      }
    }
    .opacity(isDisabled && !isWorking ? 0.46 : 1)
    .overlay(Circle().stroke(borderColor, lineWidth: 1))
    .clipShape(Circle())
    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 9, y: 4)
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }

  private var buttonBackground: some View {
    Circle().fill(.thinMaterial)
  }
}

private struct SimulatorBuildErrorBanner: View {
  let message: String
  let providerKind: SessionProviderKind
  let canSend: Bool
  let onSend: () -> Void
  let onDismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var borderColor: Color {
    Color.red.opacity(colorScheme == .dark ? 0.34 : 0.24)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("Simulator error")
          .font(.caption.weight(.semibold))

        Text(message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(5)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if canSend {
        Button {
          onSend()
        } label: {
          Label("Fix", systemImage: "wrench.and.screwdriver.fill")
        }
        .font(.caption.weight(.medium))
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(Color.brandPrimary(for: providerKind))
        .help("Ask \(providerKind.rawValue) to fix this simulator error")
        .accessibilityLabel("Fix simulator error with \(providerKind.rawValue)")
      }

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .foregroundStyle(.secondary)
      .padding(.top, 1)
      .help("Dismiss")
      .accessibilityLabel("Dismiss simulator error")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(borderColor, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 10, y: 4)
    .help(message)
  }
}
