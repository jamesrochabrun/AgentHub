//
//  CollapsibleSelectedSessionsPanel.swift
//  AgentHub
//
//  Collapsible bottom panel for displaying selected/monitored sessions.
//

import SwiftUI

// MARK: - CollapsibleSelectedSessionsPanel (Multi-Provider)

public struct CollapsibleSelectedSessionsPanel: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel
  @Binding var primarySessionId: String?

  @Environment(\.colorScheme) private var colorScheme

  @AppStorage(AgentHubDefaults.selectedSessionsPanelSizeMode)
  private var sizeModeRawValue: Int = PanelSizeMode.small.rawValue

  private let headerHeight: CGFloat = 40

  private var sizeMode: PanelSizeMode {
    PanelSizeMode(rawValue: sizeModeRawValue) ?? .small
  }

  private var headerTextColor: Color {
    colorScheme == .dark ? .black : .white
  }

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    primarySessionId: Binding<String?>
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self._primarySessionId = primarySessionId
  }

  private var monitoredCount: Int {
    claudeViewModel.monitoredSessions.count +
    codexViewModel.monitoredSessions.count +
    claudeViewModel.pendingHubSessions.count +
    codexViewModel.pendingHubSessions.count
  }

  public var body: some View {
    if monitoredCount > 0 {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          Spacer(minLength: 0)

          VStack(spacing: 0) {
            headerBar(availableHeight: geometry.size.height)

            if sizeMode != .collapsed {
              contentArea
            }
          }
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 16))
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sizeMode)
      .onAppear {
        ensurePrimarySelection()
      }
      .onChange(of: items.map(\.id)) { _, _ in
        ensurePrimarySelection()
      }
    }
  }

  // MARK: - Header Bar

  private func headerBar(availableHeight: CGFloat) -> some View {
    HStack(spacing: 8) {
      Image(systemName: sizeMode.chevronIcon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(headerTextColor.opacity(0.7))
        .frame(width: 12)

      Text("Selected")
        .font(.system(.subheadline, weight: .medium))
        .foregroundColor(headerTextColor)

      Text("(\(monitoredCount))")
        .font(.caption)
        .foregroundColor(headerTextColor.opacity(0.7))

      Spacer()

    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(height: headerHeight)
    .background(Color.secondary)
    .contentShape(Rectangle())
    .onTapGesture { cycleSize() }
  }

  private func cycleSize() {
    sizeModeRawValue = sizeMode.next().rawValue
  }

  // MARK: - Content Area

  private var contentArea: some View {
    ScrollView(showsIndicators: false) {
      LazyVStack(spacing: 6) {
        ForEach(items) { item in
          CollapsibleSessionRow(
            session: item.session,
            providerKind: item.providerKind,
            timestamp: item.timestamp,
            isPending: item.isPending,
            isPrimary: item.id == primarySessionId,
            customName: customName(for: item)
          ) {
            primarySessionId = item.id
          }
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 4)
    }
  }

  // MARK: - Data

  private struct SelectedSessionItem: Identifiable {
    let id: String
    let session: CLISession
    let providerKind: SessionProviderKind
    let timestamp: Date
    let isPending: Bool
  }

  private var items: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in claudeViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-claude-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .claude,
        timestamp: pending.startedAt,
        isPending: true
      ))
    }

    for pending in codexViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-codex-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .codex,
        timestamp: pending.startedAt,
        isPending: true
      ))
    }

    for item in claudeViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "claude-\(item.session.id)",
        session: item.session,
        providerKind: .claude,
        timestamp: item.state?.lastActivityAt ?? item.session.lastActivityAt,
        isPending: false
      ))
    }

    for item in codexViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "codex-\(item.session.id)",
        session: item.session,
        providerKind: .codex,
        timestamp: item.state?.lastActivityAt ?? item.session.lastActivityAt,
        isPending: false
      ))
    }

    return results.sorted { $0.timestamp > $1.timestamp }
  }

  private func customName(for item: SelectedSessionItem) -> String? {
    switch item.providerKind {
    case .claude:
      return claudeViewModel.sessionCustomNames[item.session.id]
    case .codex:
      return codexViewModel.sessionCustomNames[item.session.id]
    }
  }

  private func ensurePrimarySelection() {
    guard !items.isEmpty else {
      primarySessionId = nil
      return
    }

    if let current = primarySessionId, items.contains(where: { $0.id == current }) {
      return
    }

    primarySessionId = items.first?.id
  }
}

// MARK: - SingleProviderCollapsibleSelectedSessionsPanel

public struct SingleProviderCollapsibleSelectedSessionsPanel: View {
  @Bindable var viewModel: CLISessionsViewModel
  @Binding var primarySessionId: String?

  @Environment(\.colorScheme) private var colorScheme

  @AppStorage(AgentHubDefaults.selectedSessionsPanelSizeMode)
  private var sizeModeRawValue: Int = PanelSizeMode.small.rawValue

  private let headerHeight: CGFloat = 40

  private var sizeMode: PanelSizeMode {
    PanelSizeMode(rawValue: sizeModeRawValue) ?? .small
  }

  private var headerTextColor: Color {
    colorScheme == .dark ? .black : .white
  }

  public init(
    viewModel: CLISessionsViewModel,
    primarySessionId: Binding<String?>
  ) {
    self.viewModel = viewModel
    self._primarySessionId = primarySessionId
  }

  private var monitoredCount: Int {
    viewModel.monitoredSessions.count + viewModel.pendingHubSessions.count
  }

  public var body: some View {
    if monitoredCount > 0 {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          Spacer(minLength: 0)

          VStack(spacing: 0) {
            headerBar(availableHeight: geometry.size.height)

            if sizeMode != .collapsed {
              contentArea
            }
          }
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 16))
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sizeMode)
      .onAppear {
        ensurePrimarySelection()
      }
      .onChange(of: items.map(\.id)) { _, _ in
        ensurePrimarySelection()
      }
    }
  }

  // MARK: - Header Bar

  private func headerBar(availableHeight: CGFloat) -> some View {
    HStack(spacing: 8) {
      Image(systemName: sizeMode.chevronIcon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(headerTextColor.opacity(0.7))
        .frame(width: 12)

      Text("Selected")
        .font(.system(.subheadline, weight: .medium))
        .foregroundColor(headerTextColor)

      Text("(\(monitoredCount))")
        .font(.caption)
        .foregroundColor(headerTextColor.opacity(0.7))

      Spacer()

    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(height: headerHeight)
    .background(Color.secondary)
    .contentShape(Rectangle())
    .onTapGesture { cycleSize() }
  }

  private func cycleSize() {
    sizeModeRawValue = sizeMode.next().rawValue
  }

  // MARK: - Content Area

  private var contentArea: some View {
    ScrollView(showsIndicators: false) {
      LazyVStack(spacing: 6) {
        ForEach(items) { item in
          CollapsibleSessionRow(
            session: item.session,
            providerKind: viewModel.providerKind,
            timestamp: item.timestamp,
            isPending: item.isPending,
            isPrimary: item.id == primarySessionId,
            customName: viewModel.sessionCustomNames[item.session.id]
          ) {
            primarySessionId = item.id
          }
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 4)
    }
  }

  // MARK: - Data

  private struct SelectedSessionItem: Identifiable {
    let id: String
    let session: CLISession
    let timestamp: Date
    let isPending: Bool
  }

  private var items: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in viewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        timestamp: pending.startedAt,
        isPending: true
      ))
    }

    for item in viewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: item.session.id,
        session: item.session,
        timestamp: item.state?.lastActivityAt ?? item.session.lastActivityAt,
        isPending: false
      ))
    }

    return results.sorted { $0.timestamp > $1.timestamp }
  }

  private func ensurePrimarySelection() {
    guard !items.isEmpty else {
      primarySessionId = nil
      return
    }

    if let current = primarySessionId, items.contains(where: { $0.id == current }) {
      return
    }

    primarySessionId = items.first?.id
  }
}

// MARK: - CollapsibleSessionRow

private struct CollapsibleSessionRow: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let timestamp: Date
  let isPending: Bool
  let isPrimary: Bool
  let customName: String?
  let onSelect: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(isPrimary ? Color.brandPrimary(for: providerKind) : .gray.opacity(0.5))
        .frame(width: 6, height: 6)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if let customName {
            Text(customName)
              .font(.system(.caption, design: .monospaced, weight: .medium))
              .lineLimit(1)
          } else if let slug = session.slug {
            Text(slug)
              .font(.system(.caption, design: .monospaced, weight: .medium))
              .lineLimit(1)
          } else {
            Text(session.shortId)
              .font(.system(.caption, design: .monospaced, weight: .medium))
              .lineLimit(1)
          }

          if isPending {
            Text("Starting")
              .font(.system(size: 9))
              .foregroundColor(.secondary)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.12))
              .clipShape(RoundedRectangle(cornerRadius: 3))
          }
        }

        HStack(spacing: 4) {
          if let branch = session.branchName {
            Text(branch)
              .font(.system(size: 10))
              .foregroundColor(.secondary)
              .lineLimit(1)
          }

          Text(timestamp.timeAgoDisplay())
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.7))
        }
      }

      Spacer()

      Text(providerKind.rawValue)
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.brandPrimary(for: providerKind))

      if isPrimary {
        Image(systemName: "star.fill")
          .font(.system(size: 9))
          .foregroundColor(.brandPrimary(for: providerKind))
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isPrimary ? Color.brandPrimary(for: providerKind).opacity(0.1) : Color.clear)
    )
  }
}
