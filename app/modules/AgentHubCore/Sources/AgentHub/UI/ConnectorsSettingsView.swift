//
//  ConnectorsSettingsView.swift
//  AgentHub
//

import SwiftUI

@MainActor
@Observable
final class ConnectorsSettingsViewModel {
  let connectors = MCPConnectorCatalog.all
  private(set) var statuses: [String: MCPConnectorInstallationStatus] = [:]
  private(set) var isLoading = false
  private(set) var pendingConnectorID: String?
  var errorMessage: String?

  @ObservationIgnored private var service: (any MCPConnectorInstallServiceProtocol)?

  func load(service: (any MCPConnectorInstallServiceProtocol)?) async {
    self.service = service
    await refresh()
  }

  func refresh() async {
    guard let service else { return }
    isLoading = true
    defer { isLoading = false }

    for connector in connectors {
      statuses[connector.id] = await service.installationStatus(for: connector)
    }
  }

  func toggle(_ connector: MCPConnectorDefinition) async {
    guard let service else { return }
    pendingConnectorID = connector.id
    errorMessage = nil
    defer { pendingConnectorID = nil }

    do {
      if statuses[connector.id]?.isGloballyInstalled == true {
        try await service.remove(connector)
      } else {
        try await service.install(connector)
      }
      statuses[connector.id] = await service.installationStatus(for: connector)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func actionTitle(for connector: MCPConnectorDefinition) -> String {
    statuses[connector.id]?.isGloballyInstalled == true ? "Remove" : "Add"
  }

  func statusText(for connector: MCPConnectorDefinition) -> String {
    guard let status = statuses[connector.id] else { return "Checking..." }
    if status.isGloballyInstalled {
      return "Globally installed"
    }
    if status.claude.isInstalled || status.codex.isInstalled {
      return "Partially installed"
    }
    return "Not installed"
  }
}

public struct ConnectorsSettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var viewModel = ConnectorsSettingsViewModel()

  public init() {}

  public var body: some View {
    Form {
      Section("MCP Connectors") {
        ForEach(viewModel.connectors) { connector in
          connectorRow(connector)
        }
      }

      if let errorMessage = viewModel.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
    .task {
      await viewModel.load(service: agentHub?.mcpConnectorInstallService)
    }
  }

  private func connectorRow(_ connector: MCPConnectorDefinition) -> some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text(connector.name)
            .font(.headline)

          ForEach(connector.tags, id: \.self) { tag in
            Text(tag)
              .font(.caption2)
              .fontWeight(.semibold)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(Color.secondary.opacity(0.12))
              .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
          }

          Spacer()
        }

        Text(connector.url.absoluteString)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        HStack(spacing: 8) {
          Text(viewModel.statusText(for: connector))
            .font(.caption)
            .foregroundStyle(.secondary)

          if let status = viewModel.statuses[connector.id] {
            providerStatusLabel("Claude", state: status.claude)
            providerStatusLabel("Codex", state: status.codex)
          }
        }
      }

      Spacer(minLength: 12)

      if viewModel.pendingConnectorID == connector.id {
        ProgressView()
          .controlSize(.small)
      }

      Button(viewModel.actionTitle(for: connector)) {
        Task {
          await viewModel.toggle(connector)
        }
      }
      .disabled(viewModel.pendingConnectorID != nil || agentHub?.mcpConnectorInstallService == nil)
    }
    .padding(.vertical, 6)
  }

  private func providerStatusLabel(
    _ title: String,
    state: MCPConnectorProviderInstallState
  ) -> some View {
    Label(title, systemImage: statusIcon(for: state))
      .font(.caption2)
      .foregroundStyle(statusColor(for: state))
      .help("\(title): \(state.displayName)")
  }

  private func statusIcon(for state: MCPConnectorProviderInstallState) -> String {
    switch state {
    case .installed:
      return "checkmark.circle.fill"
    case .missing:
      return "circle"
    case .needsUpdate:
      return "arrow.triangle.2.circlepath.circle"
    case .invalidConfig:
      return "exclamationmark.triangle.fill"
    }
  }

  private func statusColor(for state: MCPConnectorProviderInstallState) -> Color {
    switch state {
    case .installed:
      return .green
    case .missing:
      return .secondary
    case .needsUpdate:
      return .orange
    case .invalidConfig:
      return .red
    }
  }

  @ViewBuilder
  private var settingsBackground: some View {
    if runtimeTheme?.hasCustomBackgrounds == true {
      Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    } else {
      Color.clear
    }
  }
}

