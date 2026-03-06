//
//  SimulatorPickerView.swift
//  AgentHub
//
//  Side-panel view for managing run destinations (iOS simulators and My Mac).
//  Mirrors the WebPreviewView interface: isEmbedded + onDismiss.
//

import SwiftUI

// MARK: - SimulatorPickerView

public struct SimulatorPickerView: View {
  let session: CLISession
  let onDismiss: () -> Void
  let onSendToSession: ((String) -> Void)?
  var isEmbedded: Bool = false

  @State private var preferredUDID: String?
  @State private var platforms: Set<XcodePlatform> = []
  @State private var isLoadingPlatforms = true
  @Environment(\.colorScheme) private var colorScheme

  public init(
    session: CLISession,
    onDismiss: @escaping () -> Void,
    onSendToSession: ((String) -> Void)? = nil,
    isEmbedded: Bool = false
  ) {
    self.session = session
    self.onDismiss = onDismiss
    self.onSendToSession = onSendToSession
    self.isEmbedded = isEmbedded
  }

  public var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()
      content
    }
    .frame(
      minWidth: isEmbedded ? 320 : 600, idealWidth: isEmbedded ? .infinity : 700, maxWidth: .infinity,
      minHeight: isEmbedded ? 300 : 500, idealHeight: isEmbedded ? .infinity : 600, maxHeight: .infinity
    )
    .task {
      async let devicesTask: Void = SimulatorService.shared.listDevices()
      let detected = await Task.detached {
        XcodeProjectDetector.supportedPlatforms(at: session.projectPath)
      }.value
      platforms = detected
      isLoadingPlatforms = false
      _ = await devicesTask
    }
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
  }

  // MARK: - Header

  private var headerBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "display")
        .foregroundColor(.secondary)
      Text(URL(fileURLWithPath: session.projectPath).lastPathComponent)
        .font(.system(.headline, design: .monospaced))
        .lineLimit(1)

      Spacer()

      if SimulatorService.shared.isLoadingDevices {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
      } else {
        Button(action: { Task { await SimulatorService.shared.listDevices() } }) {
          Image(systemName: "arrow.clockwise")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Refresh device list")
      }

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Close")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color.surfaceElevated)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if isLoadingPlatforms
        || (platforms.contains(.iOS)
            && SimulatorService.shared.isLoadingDevices
            && SimulatorService.shared.runtimes.isEmpty) {
      loadingState
    } else if !platforms.contains(.macOS) && !hasIOSDevices {
      emptyState
    } else {
      platformAwareList
    }
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .scaleEffect(0.8)
      Text("Loading destinations...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "iphone.slash")
        .font(.largeTitle)
        .foregroundColor(.secondary.opacity(0.5))
      Text("No Destinations Found")
        .font(.headline)
        .foregroundColor(.secondary)
      Text("Make sure Xcode is installed and the project has a supported platform configuration.")
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Platform-Aware List

  private var platformAwareList: some View {
    ScrollView {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        if platforms.contains(.macOS) {
          macSection
        }
        if platforms.contains(.iOS) && hasIOSDevices {
          iosDeviceSections
        }
      }
    }
  }

  // MARK: - macOS Section

  @ViewBuilder
  private var macSection: some View {
    let macState = SimulatorService.shared.macRunStates[session.projectPath] ?? .idle
    Section(header: macSectionHeader) {
      macRow(state: macState)
      Divider()
        .padding(.leading, 16)
    }
  }

  private var macSectionHeader: some View {
    HStack {
      Text("My Mac")
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.secondary)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.94))
  }

  private func macRow(state: MacRunState) -> some View {
    let errorText: String = {
      if case .failed(let e) = state { return e }
      return ""
    }()

    return HStack(spacing: 10) {
      StatusDotView(
        color: macStatusColor(for: state),
        isAnimating: {
          if case .building = state { return true }
          return false
        }()
      )

      VStack(alignment: .leading, spacing: 2) {
        Text("My Mac")
          .font(.system(.body))
          .lineLimit(1)
        Text(macStateLabel(for: state))
          .font(.caption)
          .foregroundColor(macStateLabelColor(for: state))
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      macActionButton(state: state)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .help(errorText)
  }

  @ViewBuilder
  private func macActionButton(state: MacRunState) -> some View {
    switch state {
    case .building:
      HStack(spacing: 6) {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
        Text("Building...")
          .font(.caption)
          .foregroundColor(.secondary)
        Button("Cancel") {
          SimulatorService.shared.cancelBuild(projectPath: session.projectPath)
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.red)
      }
    case .failed(let error):
      HStack(spacing: 6) {
        if onSendToSession != nil {
          Button("Fix with Claude") {
            onSendToSession?(error)
          }
          .font(.caption)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.accentColor)
        }
        Button("Build & Run") {
          Task {
            await SimulatorService.shared.buildAndRunOnMac(projectPath: session.projectPath)
          }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    case .idle, .done:
      Button("Build & Run") {
        Task {
          await SimulatorService.shared.buildAndRunOnMac(projectPath: session.projectPath)
        }
      }
      .font(.caption)
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  // MARK: - iOS Sections

  @ViewBuilder
  private var iosDeviceSections: some View {
    ForEach(SimulatorService.shared.runtimes) { runtime in
      if !runtime.availableDevices.isEmpty {
        Section(header: runtimeHeader(runtime)) {
          ForEach(runtime.availableDevices) { device in
            deviceRow(device)
            Divider()
              .padding(.leading, 16)
          }
        }
      }
    }
  }

  // MARK: - Runtime Header

  private func runtimeHeader(_ runtime: SimulatorRuntime) -> some View {
    HStack {
      Text(runtime.displayName)
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.secondary)
      Spacer()
      Text("\(runtime.availableDevices.count)")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.94))
  }

  // MARK: - Device Row

  private func deviceRow(_ device: SimulatorDevice) -> some View {
    let serviceState = SimulatorService.shared.state(for: device.udid, projectPath: session.projectPath)

    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      // Status dot
      StatusDotView(
        color: statusColor(for: serviceState, device: device),
        isAnimating: {
          switch serviceState {
          case .booting, .building, .installing, .launching, .shuttingDown: return true
          default: return false
          }
        }()
      )

      // Device info
      VStack(alignment: .leading, spacing: 2) {
        Text(device.name)
          .font(.system(.body, design: .default))
          .lineLimit(1)
        Text(stateLabel(for: serviceState, device: device))
          .font(.caption)
          .foregroundColor(stateLabelColor(for: serviceState))
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      // Action buttons
      actionButtons(for: device, state: serviceState)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .background(
      preferredUDID == device.udid
        ? Color.accentColor.opacity(0.08)
        : Color.clear
    )
    .onTapGesture {
      preferredUDID = device.udid
    }
  }

  @ViewBuilder
  private func actionButtons(for device: SimulatorDevice, state: SimulatorState) -> some View {
    switch state {
    case .idle:
      if device.isBooted {
        // Device is booted externally — treat as booted
        openButton(udid: device.udid)
        shutdownButton(udid: device.udid)
      } else {
        runButton(udid: device.udid)
      }

    case .booting:
      HStack(spacing: 6) {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
        Text("Booting...")
          .font(.caption)
          .foregroundColor(.secondary)
      }

    case .building:
      HStack(spacing: 6) {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
        Text("Building...")
          .font(.caption)
          .foregroundColor(.secondary)
        cancelButton(udid: device.udid)
      }

    case .installing:
      HStack(spacing: 6) {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
        Text("Installing...")
          .font(.caption)
          .foregroundColor(.secondary)
        cancelButton(udid: device.udid)
      }

    case .launching:
      HStack(spacing: 6) {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
        Text("Launching...")
          .font(.caption)
          .foregroundColor(.secondary)
        cancelButton(udid: device.udid)
      }

    case .booted:
      openButton(udid: device.udid)
      shutdownButton(udid: device.udid)

    case .shuttingDown:
      HStack(spacing: 6) {
        ProgressView()
          .scaleEffect(0.6)
          .frame(width: 16, height: 16)
        Text("Shutting down...")
          .font(.caption)
          .foregroundColor(.secondary)
      }

    case .failed(let error):
      HStack(spacing: 6) {
        if onSendToSession != nil {
          Button("Fix with Claude") {
            onSendToSession?(error)
          }
          .font(.caption)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.accentColor)
        }
        runButton(udid: device.udid)
      }
    }
  }

  private func runButton(udid: String) -> some View {
    Button {
      Task {
        await SimulatorService.shared.buildAndRunOnSimulator(
          udid: udid,
          projectPath: session.projectPath
        )
      }
    } label: {
      Image(systemName: "play.fill")
        .font(.caption)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func cancelButton(udid: String) -> some View {
    Button {
      SimulatorService.shared.cancelSimulatorBuild(udid: udid, projectPath: session.projectPath)
    } label: {
      Image(systemName: "stop.fill")
        .font(.caption)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .tint(.red)
  }

  private func openButton(udid: String) -> some View {
    Button("Open") {
      Task {
        await SimulatorService.shared.openSimulatorApp()
      }
    }
    .font(.caption)
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func shutdownButton(udid: String) -> some View {
    Button("Shutdown") {
      Task {
        await SimulatorService.shared.shutdownDevice(udid: udid)
      }
    }
    .font(.caption)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .tint(.red)
  }

  // MARK: - Helpers

  private var hasIOSDevices: Bool {
    !SimulatorService.shared.runtimes.isEmpty
      && SimulatorService.shared.runtimes.contains(where: { !$0.availableDevices.isEmpty })
  }

  private func macStatusColor(for state: MacRunState) -> Color {
    switch state {
    case .idle: return .gray.opacity(0.5)
    case .building: return .yellow
    case .done: return .green
    case .failed: return .red
    }
  }

  private func macStateLabel(for state: MacRunState) -> String {
    switch state {
    case .idle: return "Ready"
    case .building: return "Building..."
    case .done: return "Running"
    case .failed: return "Build failed"
    }
  }

  private func statusColor(for state: SimulatorState, device: SimulatorDevice) -> Color {
    switch state {
    case .idle:
      return device.isBooted ? .green : .gray.opacity(0.5)
    case .booting, .building, .installing, .launching:
      return .yellow
    case .booted:
      return .green
    case .shuttingDown:
      return .orange
    case .failed:
      return .red
    }
  }

  private func stateLabel(for state: SimulatorState, device: SimulatorDevice) -> String {
    switch state {
    case .idle:
      return device.isBooted ? "Booted" : "Available"
    case .booting:
      return "Booting..."
    case .building:
      return "Building..."
    case .installing:
      return "Installing..."
    case .launching:
      return "Launching..."
    case .booted:
      return "Booted"
    case .shuttingDown:
      return "Shutting Down..."
    case .failed:
      return "Build failed"
    }
  }

  private func stateLabelColor(for state: SimulatorState) -> Color {
    if case .failed = state { return .red }
    return .secondary
  }

  private func macStateLabelColor(for state: MacRunState) -> Color {
    if case .failed = state { return .red }
    return .secondary
  }
}

// MARK: - StatusDotView

private struct StatusDotView: View {
  let color: Color
  let isAnimating: Bool
  @State private var pulse = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .opacity(isAnimating ? (pulse ? 0.35 : 1.0) : 1.0)
      .onAppear {
        guard isAnimating else { return }
        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
          pulse = true
        }
      }
  }
}
