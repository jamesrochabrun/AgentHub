//
//  CLISessionsListView.swift
//  AgentHub
//
//  Created by Assistant on 1/9/26.
//

import Foundation
import SwiftUI

// MARK: - CLISessionsListView

/// Main list view for displaying CLI sessions with repository-based organization
/// State for terminal branch switch confirmation
private struct TerminalConfirmation: Identifiable {
  let id = UUID()
  let worktree: WorktreeBranch
  let currentBranch: String
}

public struct CLISessionsListView: View {
  @Bindable var viewModel: CLISessionsViewModel
  @State private var createWorktreeRepository: SelectedRepository?
  @State private var terminalConfirmation: TerminalConfirmation?
  @Environment(\.colorScheme) private var colorScheme

  public init(viewModel: CLISessionsViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    HSplitView {
      // Left panel: Session list
      sessionListPanel
        .padding(12)
        .agentHubPanel()
        .frame(minWidth: 300, idealWidth: 400)
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 4)

      // Right panel: Monitoring
      MonitoringPanelView(viewModel: viewModel)
        .padding(12)
        .agentHubPanel()
        .frame(minWidth: 300, idealWidth: 350)
        .padding(.vertical, 8)
        .padding(.leading, 4)
        .padding(.trailing, 8)
    }
    .background(appBackground.ignoresSafeArea())
    .onAppear {
      // Auto-refresh sessions when view appears
      if viewModel.hasRepositories {
        viewModel.refresh()
      }
    }
    .sheet(item: $createWorktreeRepository) { repository in
      CreateWorktreeSheet(
        repositoryPath: repository.path,
        repositoryName: repository.name,
        onDismiss: { createWorktreeRepository = nil },
        onCreate: { branchName, directory, baseBranch, onProgress in
          try await viewModel.createWorktree(
            for: repository,
            branchName: branchName,
            directoryName: directory,
            baseBranch: baseBranch,
            onProgress: onProgress
          )
        }
      )
    }
    .alert(
      "Switch Branch?",
      isPresented: Binding(
        get: { terminalConfirmation != nil },
        set: { if !$0 { terminalConfirmation = nil } }
      ),
      presenting: terminalConfirmation
    ) { confirmation in
      Button("Cancel", role: .cancel) {
        terminalConfirmation = nil
      }
      Button("Switch & Open") {
        if let error = viewModel.openTerminalInWorktree(confirmation.worktree, skipCheckout: false) {
          print("Failed to open terminal: \(error.localizedDescription)")
        }
        terminalConfirmation = nil
      }
    } message: { confirmation in
      Text("You have uncommitted changes on '\(confirmation.currentBranch)'. Switching to '\(confirmation.worktree.name)' may fail or carry changes over.")
    }
  }

  // MARK: - App Background

  private var appBackground: some View {
    LinearGradient(
      colors: [
        Color.surfaceCanvas,
        Color.surfaceCanvas.opacity(colorScheme == .dark ? 0.98 : 0.94),
        Color.brandTertiary.opacity(colorScheme == .dark ? 0.06 : 0.1)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Session List Panel

  private var sessionListPanel: some View {
    VStack(spacing: 0) {
      // Add repository button (always visible)
      CLIRepositoryPickerView(onAddRepository: viewModel.showAddRepositoryPicker)
        .padding(.bottom, 10)

      if viewModel.isLoading && !viewModel.hasRepositories {
        loadingView
      } else if !viewModel.hasRepositories {
        CLIEmptyStateView(onAddRepository: viewModel.showAddRepositoryPicker)
      } else {
        repositoriesList
      }
    }
  }

  // MARK: - Loading View

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
        .progressViewStyle(CircularProgressViewStyle())
      Text(viewModel.loadingState.message)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Repositories List

  private var repositoriesList: some View {
    ScrollView {
      LazyVStack(spacing: 12) {
        // Status header
        statusHeader

        // Repository tree views
        ForEach(viewModel.selectedRepositories) { repository in
          CLIRepositoryTreeView(
            repository: repository,
            onRemove: { viewModel.removeRepository(repository) },
            onToggleExpanded: { viewModel.toggleRepositoryExpanded(repository) },
            onToggleWorktreeExpanded: { worktree in
              viewModel.toggleWorktreeExpanded(in: repository, worktree: worktree)
            },
            onConnectSession: { session in
              if let error = viewModel.connectToSession(session) {
                print("Failed to connect: \(error.localizedDescription)")
              }
            },
            onCopySessionId: { session in
              viewModel.copySessionId(session)
            },
            isSessionMonitored: { sessionId in
              viewModel.isMonitoring(sessionId: sessionId)
            },
            onToggleMonitoring: { session in
              viewModel.toggleMonitoring(for: session)
            },
            onCreateWorktree: {
              createWorktreeRepository = repository
            },
            onOpenTerminalForWorktree: { worktree in
              Task {
                let check = await viewModel.checkBeforeOpeningTerminal(worktree)

                if !check.needsCheckout {
                  // Already on correct branch or is a worktree - open directly
                  if let error = viewModel.openTerminalInWorktree(worktree, skipCheckout: true) {
                    print("Failed to open terminal: \(error.localizedDescription)")
                  }
                } else if check.hasUncommittedChanges {
                  // Need checkout but have uncommitted changes - show confirmation
                  terminalConfirmation = TerminalConfirmation(
                    worktree: worktree,
                    currentBranch: check.currentBranch
                  )
                } else {
                  // Need checkout but no uncommitted changes - proceed with checkout
                  if let error = viewModel.openTerminalInWorktree(worktree, skipCheckout: false) {
                    print("Failed to open terminal: \(error.localizedDescription)")
                  }
                }
              }
            },
            showLastMessage: viewModel.showLastMessage
          )
        }
      }
      .padding(.vertical, 8)
    }
  }

  // MARK: - Status Header

  private var statusHeader: some View {
    VStack(spacing: 8) {
      // Loading indicator (when loading with repositories)
      if viewModel.isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .scaleEffect(0.7)
          Text(viewModel.loadingState.message)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(Color.blue.opacity(0.1))
        )
      }

      HStack {
        // Session count
        if viewModel.activeSessionCount > 0 {
          HStack(spacing: 6) {
            Circle()
              .fill(Color.green)
              .frame(width: DesignTokens.StatusSize.sm, height: DesignTokens.StatusSize.sm)
              .shadow(color: .green.opacity(0.4), radius: 2)
            Text("\(viewModel.activeSessionCount) active")
              .font(.system(.caption, weight: .medium))
              .foregroundColor(.green)
          }
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .padding(.vertical, DesignTokens.Spacing.xs)
          .background(
            Capsule()
              .fill(Color.green.opacity(0.1))
          )
        }

        Text("\(viewModel.totalSessionCount) total sessions")
          .font(.caption)
          .foregroundColor(.secondary)

        Spacer()

        // Approval timeout picker
        Menu {
          ForEach([3, 5, 10, 15, 30], id: \.self) { seconds in
            Button(action: { viewModel.approvalTimeoutSeconds = seconds }) {
              HStack {
                Text("\(seconds)s")
                if viewModel.approvalTimeoutSeconds == seconds {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "bell")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text("\(viewModel.approvalTimeoutSeconds)s")
              .font(.system(.caption, weight: .medium))
          }
          .foregroundColor(.secondary)
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .padding(.vertical, DesignTokens.Spacing.xs + 2)
          .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
              .fill(Color.surfaceOverlay)
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
              .stroke(Color.borderSubtle, lineWidth: 1)
          )
        }
        .menuStyle(.borderlessButton)
        .help("Alert sound delay: \(viewModel.approvalTimeoutSeconds) seconds")

        // First/Last message toggle
        Button(action: { viewModel.showLastMessage.toggle() }) {
          HStack(spacing: 6) {
            Image(systemName: viewModel.showLastMessage ? "arrow.down.to.line" : "arrow.up.to.line")
              .font(.system(size: DesignTokens.IconSize.sm))
            Text(viewModel.showLastMessage ? "Last" : "First")
              .font(.system(.caption, weight: .medium))
          }
          .foregroundColor(.secondary)
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .padding(.vertical, DesignTokens.Spacing.xs + 2)
          .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
              .fill(Color.surfaceOverlay)
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
              .stroke(Color.borderSubtle, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
        .help(viewModel.showLastMessage ? "Showing last message" : "Showing first message")

        // Refresh button
        Button(action: viewModel.refresh) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: DesignTokens.IconSize.md))
            .frame(width: 28, height: 28)
            .background(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(Color.surfaceOverlay)
            )
            .overlay(
              RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .stroke(Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
        .help("Refresh sessions")
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.xs)
  }
}

// MARK: - Preview

#Preview {
  let service = CLISessionMonitorService()
  let viewModel = CLISessionsViewModel(monitorService: service)

  return CLISessionsListView(viewModel: viewModel)
    .frame(width: 800, height: 600)
}
