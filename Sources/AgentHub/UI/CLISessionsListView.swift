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
public struct CLISessionsListView: View {
  @Bindable var viewModel: CLISessionsViewModel
  @State private var createWorktreeRepository: SelectedRepository?

  public init(viewModel: CLISessionsViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    HSplitView {
      // Left panel: Session list
      sessionListPanel
        .frame(minWidth: 300, idealWidth: 400)

      // Right panel: Monitoring
      MonitoringPanelView(viewModel: viewModel)
        .frame(minWidth: 300, idealWidth: 350)
    }
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
        onCreate: { branchName, directory, baseBranch in
          try await viewModel.createWorktree(
            for: repository,
            branchName: branchName,
            directoryName: directory,
            baseBranch: baseBranch
          )
        }
      )
    }
  }

  // MARK: - Session List Panel

  private var sessionListPanel: some View {
    VStack(spacing: 0) {
      // Add repository button (always visible)
      CLIRepositoryPickerView(onAddRepository: viewModel.showAddRepositoryPicker)
        .padding(.horizontal, 12)
        .padding(.top, 8)

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
            showLastMessage: viewModel.showLastMessage
          )
        }
      }
      .padding(.horizontal, 12)
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
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(6)
      }

      HStack {
        // Session count
        if viewModel.activeSessionCount > 0 {
          HStack(spacing: 4) {
            Circle()
              .fill(Color.green)
              .frame(width: 6, height: 6)
            Text("\(viewModel.activeSessionCount) active")
              .font(.caption)
              .foregroundColor(.green)
          }
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
          HStack(spacing: 4) {
            Image(systemName: "bell")
            Text("\(viewModel.approvalTimeoutSeconds)s")
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.gray.opacity(0.1))
          .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .help("Alert sound delay: \(viewModel.approvalTimeoutSeconds) seconds")

        // First/Last message toggle
        Button(action: { viewModel.showLastMessage.toggle() }) {
          HStack(spacing: 4) {
            Image(systemName: viewModel.showLastMessage ? "arrow.down.to.line" : "arrow.up.to.line")
            Text(viewModel.showLastMessage ? "Last" : "First")
          }
          .font(.subheadline)
          .foregroundColor(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.gray.opacity(0.1))
          .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(viewModel.showLastMessage ? "Showing last message" : "Showing first message")

        // Refresh button
        Button(action: viewModel.refresh) {
          Image(systemName: "arrow.clockwise")
            .font(.subheadline)
            .padding(6)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
        .help("Refresh sessions")
      }
    }
    .padding(.horizontal, 4)
  }
}

// MARK: - Preview

#Preview {
  let service = CLISessionMonitorService()
  let viewModel = CLISessionsViewModel(monitorService: service)

  return CLISessionsListView(viewModel: viewModel)
    .frame(width: 800, height: 600)
}
