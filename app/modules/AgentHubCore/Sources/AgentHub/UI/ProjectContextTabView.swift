//
//  ProjectContextTabView.swift
//  AgentHub
//
//  The Project Details Context tab: saved context profiles as cards (with
//  scope chips and token badges), plus the panel's first editing surface —
//  create, edit, delete, and set-default — via the shared Context Builder.
//

import SwiftUI

// MARK: - Editor state

enum ProjectContextEditorState: Identifiable {
  case create
  case edit(ContextProfile)

  var id: String {
    switch self {
    case .create: return "create"
    case .edit(let profile): return profile.id
    }
  }
}

// MARK: - Tab (grid)

struct ProjectContextTabView: View {
  let viewModel: ProjectContextViewModel
  @Binding var scopeFilter: ProjectDetailsScopeFilter
  let onEdit: (ContextProfile) -> Void
  let onNew: () -> Void
  @Environment(\.runtimeTheme) private var runtimeTheme

  private let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12)
  ]

  var body: some View {
    if !viewModel.isAvailable {
      ProjectDetailsEmptyState(
        systemImage: "square.stack.3d.up",
        title: "Context sets unavailable",
        message: "The app database could not be opened, so saved context sets are disabled."
      )
    } else if viewModel.isLoading, viewModel.profiles.isEmpty {
      ProjectDetailsLoadingState()
    } else if viewModel.profiles.isEmpty {
      emptyState
    } else {
      grid
    }
  }

  /// Inline layout instead of `ProjectDetailsEmptyState` so the button sits
  /// centered with the message rather than pinned below its greedy frame.
  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "square.stack.3d.up")
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(.secondary.opacity(0.6))
      Text("No context sets yet")
        .font(.secondaryDefault)
        .foregroundStyle(.primary)
      Text("A context set is a saved bundle of files and instructions handed to every agent you launch with it. Create one here or save one from the launcher.")
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
      Button(action: onNew) {
        Label("New Context Set", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.brandPrimary(from: runtimeTheme))
      .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var grid: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        ProjectDetailsScopeFilterChips(
          filter: $scopeFilter,
          totalCount: viewModel.profiles.count,
          personalCount: viewModel.profiles.filter { $0.scope == .personal }.count,
          projectCount: viewModel.profiles.filter { $0.scope == .project }.count,
          personalLabel: "Global"
        )
        Button(action: onNew) {
          Label("New Context Set", systemImage: "plus")
            .font(.secondaryCaption)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)

      if let error = viewModel.lastActionError {
        Text(error)
          .font(.secondaryCaption)
          .foregroundColor(.red)
          .padding(.horizontal, 20)
          .padding(.top, 8)
      }

      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
          ForEach(filteredProfiles) { profile in
            ProjectContextProfileCard(
              profile: profile,
              estimatedTokens: viewModel.estimatedTokensByProfileId[profile.id],
              onOpen: { onEdit(profile) },
              onSetDefault: { Task { await viewModel.setDefault(profile) } },
              onClearDefault: { Task { await viewModel.setDefault(nil) } }
            )
          }
        }
        .padding(20)
      }
    }
  }

  private var filteredProfiles: [ContextProfile] {
    viewModel.profiles.filter { scopeFilter.allows($0.scope == .personal ? .personal : .project) }
  }
}

// MARK: - Profile card

private struct ProjectContextProfileCard: View {
  let profile: ContextProfile
  let estimatedTokens: Int?
  let onOpen: () -> Void
  let onSetDefault: () -> Void
  let onClearDefault: () -> Void

  @State private var isHovered = false
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    Button(action: onOpen) {
      HStack(alignment: .top, spacing: 10) {
        ProjectAssetCardIcon(systemImage: "square.stack.3d.up")

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(profile.name)
              .font(.primaryDefault)
              .foregroundStyle(.primary)
              .lineLimit(1)
            if profile.isDefault {
              Text("Default")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.brandPrimary(from: runtimeTheme).opacity(0.16)))
                .foregroundStyle(Color.brandPrimary(from: runtimeTheme))
            }
          }

          if !profile.selection.instructions.isEmpty {
            Text(profile.selection.instructions)
              .font(.secondarySmall)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }

          HStack(spacing: 6) {
            ProjectAssetBadge(text: profile.scope == .personal ? "Global" : "Project")
            ProjectAssetBadge(
              text: {
                let selection = profile.selection
                let count = selection.files.count + selection.externalPaths.count + selection.textSnippets.count
                return "\(count) item\(count == 1 ? "" : "s")"
              }()
            )
            if let estimatedTokens {
              ProjectAssetBadge(text: "~\(SessionMonitorState.formatTokenCount(estimatedTokens)) tokens")
            }
          }
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary.opacity(isHovered ? 0.9 : 0.4))
          .padding(.top, 4)
      }
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .projectDetailsCardBackground(highlighted: isHovered)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
    // Deletion is deliberately absent here: it lives as the explicit
    // confirmed action inside the editor, never behind a right-click.
    .contextMenu {
      if profile.scope == .project {
        if profile.isDefault {
          Button("Clear Default", action: onClearDefault)
        } else {
          Button("Set as Default", action: onSetDefault)
        }
      }
      Button("Edit", action: onOpen)
    }
  }
}

// MARK: - Editor page (create / edit)

struct ProjectContextEditorView: View {
  let state: ProjectContextEditorState
  let viewModel: ProjectContextViewModel
  let onBack: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      backBar
      Divider()
      ContextBuilderView(
        viewModel: builderViewModel,
        mode: builderMode,
        onDeleted: { Task { await viewModel.load() } },
        onDismiss: onBack
      )
      // Re-key the builder when the target changes, otherwise @State keeps the
      // previous profile's view model.
      .id(state.id)
    }
  }

  private var backBar: some View {
    HStack(spacing: 8) {
      Button(action: onBack) {
        Label("Context Sets", systemImage: "chevron.left")
          .font(.secondaryDefault)
      }
      .buttonStyle(.plain)
      .foregroundColor(.secondary)
      .keyboardShortcut(.leftArrow, modifiers: [.command])
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  private var builderViewModel: ContextBuilderViewModel {
    switch state {
    case .create:
      return ContextBuilderViewModel(
        projectPath: viewModel.projectPath,
        fileLoader: viewModel.contextFileLoader,
        profileService: viewModel.profileService
      )
    case .edit(let profile):
      return ContextBuilderViewModel(
        projectPath: viewModel.projectPath,
        initialSelection: profile.selection,
        sourceProfile: profile,
        fileLoader: viewModel.contextFileLoader,
        profileService: viewModel.profileService
      )
    }
  }

  private var builderMode: ContextBuilderMode {
    switch state {
    case .create:
      return .createProfile { _ in Task { await viewModel.load() } }
    case .edit:
      return .editProfile { _ in Task { await viewModel.load() } }
    }
  }
}
