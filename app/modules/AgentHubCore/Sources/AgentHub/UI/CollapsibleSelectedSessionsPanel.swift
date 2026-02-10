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

  @State private var showDeleteWorktreeAlert = false
  @State private var sessionToDeleteWorktree: CLISession? = nil

  private let headerHeight: CGFloat = 40

  private var sizeMode: PanelSizeMode {
    PanelSizeMode(rawValue: sizeModeRawValue) ?? .small
  }

  private var headerTextColor: Color {
    colorScheme == .dark ? .primary : .white
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
          .background(colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.92))
          .clipShape(RoundedRectangle(cornerRadius: 16))
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sizeMode)
      .onAppear {
        // Auto-expand if collapsed when sessions exist
        if sizeMode == .collapsed {
          sizeModeRawValue = PanelSizeMode.small.rawValue
        }
        ensurePrimarySelection()
      }
      .onChange(of: items.map(\.id)) { _, _ in
        ensurePrimarySelection()
      }
      .alert("Delete Worktree?", isPresented: $showDeleteWorktreeAlert) {
        Button("Cancel", role: .cancel) {
          sessionToDeleteWorktree = nil
        }
        Button("Delete", role: .destructive) {
          if let session = sessionToDeleteWorktree {
            let providerKind = items.first(where: { $0.session.id == session.id })?.providerKind
            Task {
              switch providerKind {
              case .claude:
                await claudeViewModel.deleteWorktreeForSession(session)
              case .codex:
                await codexViewModel.deleteWorktreeForSession(session)
              case .none:
                break
              }
            }
            sessionToDeleteWorktree = nil
          }
        }
      } message: {
        Text("You are about to delete this worktree. This cannot be recovered.")
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
    .background(colorScheme == .dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.black.opacity(0.8)))
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
            customName: customName(for: item),
            sessionStatus: item.sessionStatus,
            colorScheme: colorScheme,
            onArchive: item.isPending ? nil : {
              switch item.providerKind {
              case .claude: claudeViewModel.stopMonitoring(session: item.session)
              case .codex: codexViewModel.stopMonitoring(session: item.session)
              }
            },
            onDeleteWorktree: (!item.isPending && item.session.isWorktree) ? {
              sessionToDeleteWorktree = item.session
              showDeleteWorktreeAlert = true
            } : nil,
            isDeletingWorktree: item.session.isWorktree && {
              switch item.providerKind {
              case .claude: return claudeViewModel.deletingWorktreePath == item.session.projectPath
              case .codex: return codexViewModel.deletingWorktreePath == item.session.projectPath
              }
            }(),
            onSelect: {
              primarySessionId = item.id
            }
          )
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
    let sessionStatus: SessionStatus?
  }

  private var items: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in claudeViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-claude-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .claude,
        timestamp: pending.startedAt,
        isPending: true,
        sessionStatus: nil
      ))
    }

    for pending in codexViewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-codex-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        providerKind: .codex,
        timestamp: pending.startedAt,
        isPending: true,
        sessionStatus: nil
      ))
    }

    for item in claudeViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "claude-\(item.session.id)",
        session: item.session,
        providerKind: .claude,
        timestamp: item.session.lastActivityAt,
        isPending: false,
        sessionStatus: item.state?.status
      ))
    }

    for item in codexViewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: "codex-\(item.session.id)",
        session: item.session,
        providerKind: .codex,
        timestamp: item.session.lastActivityAt,
        isPending: false,
        sessionStatus: item.state?.status
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

  @State private var showDeleteWorktreeAlert = false
  @State private var sessionToDeleteWorktree: CLISession? = nil

  private let headerHeight: CGFloat = 40

  private var sizeMode: PanelSizeMode {
    PanelSizeMode(rawValue: sizeModeRawValue) ?? .small
  }

  private var headerTextColor: Color {
    colorScheme == .dark ? .primary : .white
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
          .background(colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.92))
          .clipShape(RoundedRectangle(cornerRadius: 16))
        }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sizeMode)
      .onAppear {
        // Auto-expand if collapsed when sessions exist
        if sizeMode == .collapsed {
          sizeModeRawValue = PanelSizeMode.small.rawValue
        }
        ensurePrimarySelection()
      }
      .onChange(of: items.map(\.id)) { _, _ in
        ensurePrimarySelection()
      }
      .alert("Delete Worktree?", isPresented: $showDeleteWorktreeAlert) {
        Button("Cancel", role: .cancel) {
          sessionToDeleteWorktree = nil
        }
        Button("Delete", role: .destructive) {
          if let session = sessionToDeleteWorktree {
            Task {
              await viewModel.deleteWorktreeForSession(session)
            }
            sessionToDeleteWorktree = nil
          }
        }
      } message: {
        Text("You are about to delete this worktree. This cannot be recovered.")
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
    .background(colorScheme == .dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.black.opacity(0.8)))
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
            customName: viewModel.sessionCustomNames[item.session.id],
            sessionStatus: item.sessionStatus,
            colorScheme: colorScheme,
            onArchive: item.isPending ? nil : {
              viewModel.stopMonitoring(session: item.session)
            },
            onDeleteWorktree: (!item.isPending && item.session.isWorktree) ? {
              sessionToDeleteWorktree = item.session
              showDeleteWorktreeAlert = true
            } : nil,
            isDeletingWorktree: item.session.isWorktree
              && viewModel.deletingWorktreePath == item.session.projectPath,
            onSelect: {
              primarySessionId = item.id
            }
          )
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
    let sessionStatus: SessionStatus?
  }

  private var items: [SelectedSessionItem] {
    var results: [SelectedSessionItem] = []

    for pending in viewModel.pendingHubSessions {
      results.append(SelectedSessionItem(
        id: "pending-\(pending.id.uuidString)",
        session: pending.placeholderSession,
        timestamp: pending.startedAt,
        isPending: true,
        sessionStatus: nil
      ))
    }

    for item in viewModel.monitoredSessions {
      results.append(SelectedSessionItem(
        id: item.session.id,
        session: item.session,
        timestamp: item.session.lastActivityAt,
        isPending: false,
        sessionStatus: item.state?.status
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

