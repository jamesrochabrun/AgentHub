//
//  BuildCacheStorageSettingsView.swift
//  AgentHub
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class BuildCacheStorageViewModel {
  public private(set) var snapshot: BuildCacheStorageSnapshot = .empty
  public private(set) var isLoading = false
  public private(set) var isCleaning = false
  public private(set) var errorMessage: String?
  public private(set) var cleanupMessage: String?
  public private(set) var shouldOfferAdvancedCleanup = false

  public var isBusy: Bool {
    isLoading || isCleaning
  }

  public init() {}

  public func load(provider: AgentHubProvider?) async {
    guard let provider else { return }
    isCleaning = false
    isLoading = true
    errorMessage = nil
    let paths = await provider.knownBuildCacheWorkspacePaths()
    snapshot = await provider.buildCacheService.storageSnapshot(knownWorkspacePaths: paths)
    isLoading = false
  }

  public func runCleanup(provider: AgentHubProvider?, cacheLimitGB: Int) async {
    guard let provider else { return }
    isCleaning = true
    defer { isCleaning = false }
    errorMessage = nil
    cleanupMessage = nil
    shouldOfferAdvancedCleanup = false
    let paths = await provider.knownBuildCacheWorkspacePaths()
    let previousTotal = snapshot.totalSizeBytes
    let report = await provider.buildCacheService.runGarbageCollection(knownWorkspacePaths: paths)
    snapshot = await provider.buildCacheService.storageSnapshot(knownWorkspacePaths: paths)
    cleanupMessage = cleanupSummary(
      report: report,
      previousTotal: previousTotal,
      cacheLimitGB: cacheLimitGB
    )
  }

  public func setPinned(_ pinned: Bool, entry: BuildCacheWorkspaceSummary, provider: AgentHubProvider?) async {
    guard let provider else { return }
    applyPinned(pinned, forWorkspaceID: entry.id)
    await provider.buildCacheService.setPinned(pinned, forWorkspaceID: entry.id)
  }

  public func delete(entry: BuildCacheWorkspaceSummary, provider: AgentHubProvider?) async {
    guard let provider else { return }
    do {
      try await provider.buildCacheService.deleteWorkspaceCache(id: entry.id)
      cleanupMessage = "Deleted cache for \(entry.displayPath)"
      shouldOfferAdvancedCleanup = false
      await load(provider: provider)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func clearAll(provider: AgentHubProvider?) async {
    guard let provider else { return }
    do {
      try await provider.buildCacheService.clearAllCaches()
      cleanupMessage = "Cleared build caches"
      shouldOfferAdvancedCleanup = false
      await load(provider: provider)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public static func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func applyPinned(_ pinned: Bool, forWorkspaceID id: String) {
    snapshot = BuildCacheStorageSnapshot(
      cacheRootPath: snapshot.cacheRootPath,
      totalSizeBytes: snapshot.totalSizeBytes,
      workspaces: snapshot.workspaces.map { entry in
        guard entry.id == id else { return entry }
        return BuildCacheWorkspaceSummary(
          id: entry.id,
          workspacePath: entry.workspacePath,
          sizeBytes: entry.sizeBytes,
          lastAccessed: entry.lastAccessed,
          isPinned: pinned
        )
      }
    )
  }

  private func cleanupSummary(
    report: BuildCacheCleanupReport,
    previousTotal: Int64,
    cacheLimitGB: Int
  ) -> String {
    if report.deletedBytes > 0 {
      return "Freed \(Self.formatBytes(report.deletedBytes)). Disk used is now \(Self.formatBytes(snapshot.totalSizeBytes))."
    }

    let cacheLimitBytes = Int64(max(cacheLimitGB, 1)) * 1_000_000_000
    if snapshot.totalSizeBytes > cacheLimitBytes {
      shouldOfferAdvancedCleanup = true
      return "No eligible caches were removed. Recent or kept workspace caches remain available, so disk used is still above the cleanup target."
    }

    if snapshot.totalSizeBytes <= previousTotal {
      return "No eligible caches were removed. Disk used is already within the cleanup target."
    }

    return "No eligible caches were removed."
  }
}

public struct BuildCacheStorageSettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var viewModel = BuildCacheStorageViewModel()
  @State private var entryPendingDeletion: BuildCacheWorkspaceSummary?
  @State private var showClearAllConfirmation = false
  @State private var showAdvancedCleanup = false

  @AppStorage(AgentHubDefaults.buildCacheSizeLimitGB)
  private var cacheLimitGB: Int = 10

  public init() {}

  public var body: some View {
    Form {
      Section {
        LabeledContent("Disk used") {
          Text(BuildCacheStorageViewModel.formatBytes(viewModel.snapshot.totalSizeBytes))
            .monospacedDigit()
        }

        LabeledContent("Cache folder") {
          Text(viewModel.snapshot.cacheRootPath)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
        }

        Stepper(value: cacheLimitBinding, in: 1...250, step: 1) {
          HStack {
            Text("Cleanup target")
            Spacer()
            Text("\(cacheLimitGB) GB")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      } header: {
        Text("Usage")
      } footer: {
        Text("These are rebuildable files AgentHub creates while running Xcode builds for your projects. This is disk space, not memory, and it does not include source code. The cleanup target is not a live hard limit; cleanup uses it to decide which caches can be removed.")
      }

      Section("Cleanup") {
        VStack(alignment: .leading, spacing: 14) {
          StorageActionRow(
            title: "Free Up Disk Space",
            description: "Safe to run. AgentHub removes caches it can recreate: orphaned project caches first, then older caches not marked Keep until usage is near the \(cacheLimitGB) GB target. Source code and projects are not touched; affected projects may rebuild slower next time.",
            systemImage: "sparkles",
            isLoading: viewModel.isCleaning,
            isDestructive: false,
            isDisabled: viewModel.isBusy
          ) {
            Task { await viewModel.runCleanup(provider: agentHub, cacheLimitGB: cacheLimitGB) }
          }

          Button {
            withAnimation(.easeInOut(duration: 0.15)) {
              showAdvancedCleanup.toggle()
            }
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "chevron.right")
                .font(.caption)
                .rotationEffect(.degrees(showAdvancedCleanup ? 90 : 0))
              Text("Advanced")
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityValue(showAdvancedCleanup ? "Expanded" : "Collapsed")

          if showAdvancedCleanup {
            StorageActionRow(
              title: "Delete Every Cache",
              description: "Use this only when you want the maximum disk-space reclaim. It removes all AgentHub build caches and package cache data. Nothing in your projects is deleted, but every project will rebuild cold the next time AgentHub builds it.",
              systemImage: "trash",
              isLoading: false,
              isDestructive: true,
              isDisabled: viewModel.isBusy || viewModel.snapshot.totalSizeBytes == 0
            ) {
              showClearAllConfirmation = true
            }
            .padding(.top, 8)
          }
        }

        if let cleanupMessage = viewModel.cleanupMessage {
          CleanupResultCallout(
            message: cleanupMessage,
            isWarning: viewModel.shouldOfferAdvancedCleanup,
            actionTitle: viewModel.shouldOfferAdvancedCleanup ? "Review Advanced Cleanup" : nil
          ) {
            withAnimation(.easeInOut(duration: 0.15)) {
              showAdvancedCleanup = true
            }
          }
        }

        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section {
        if viewModel.isLoading && viewModel.snapshot.workspaces.isEmpty {
          ProgressView()
        } else if viewModel.snapshot.workspaces.isEmpty {
          Text("No build caches")
            .foregroundStyle(.secondary)
        } else {
          ForEach(viewModel.snapshot.workspaces) { entry in
            BuildCacheWorkspaceRow(
              entry: entry,
              onPinChanged: { pinned in
                Task { await viewModel.setPinned(pinned, entry: entry, provider: agentHub) }
              },
              onReveal: { reveal(entry) },
              onDelete: { entryPendingDeletion = entry }
            )
          }
        }
      } header: {
        Text("Workspaces")
      } footer: {
        Text("Each row is disk cache for one project or workspace AgentHub built. Keep prevents cleanup from evicting it. Delete Cache removes only that row; the project will rebuild it next time.")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
    .task {
      await viewModel.load(provider: agentHub)
    }
    .alert(
      "Delete this cache?",
      isPresented: deleteConfirmationBinding,
      presenting: entryPendingDeletion
    ) { entry in
      Button("Cancel", role: .cancel) {
        entryPendingDeletion = nil
      }
      Button("Delete Cache", role: .destructive) {
        Task {
          await viewModel.delete(entry: entry, provider: agentHub)
          entryPendingDeletion = nil
        }
      }
    } message: { entry in
      Text(entry.displayPath)
    }
    .alert("Delete all build caches?", isPresented: $showClearAllConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete All", role: .destructive) {
        Task { await viewModel.clearAll(provider: agentHub) }
      }
    } message: {
      Text("This removes only rebuildable AgentHub build caches, not source code. The next AgentHub-started Xcode build may be slower while caches are recreated.")
    }
  }

  private var cacheLimitBinding: Binding<Int> {
    Binding(
      get: { max(cacheLimitGB, 1) },
      set: { cacheLimitGB = max($0, 1) }
    )
  }

  private var deleteConfirmationBinding: Binding<Bool> {
    Binding(
      get: { entryPendingDeletion != nil },
      set: { if !$0 { entryPendingDeletion = nil } }
    )
  }

  @ViewBuilder
  private var settingsBackground: some View {
    if runtimeTheme?.hasCustomBackgrounds == true {
      Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    } else {
      Color.clear
    }
  }

  private func reveal(_ entry: BuildCacheWorkspaceSummary) {
    #if canImport(AppKit)
    guard let workspacePath = entry.workspacePath else { return }
    let url = URL(fileURLWithPath: workspacePath)
    if FileManager.default.fileExists(atPath: workspacePath) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
    }
    #endif
  }
}

private struct BuildCacheWorkspaceRow: View {
  let entry: BuildCacheWorkspaceSummary
  let onPinChanged: (Bool) -> Void
  let onReveal: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.displayPath)
          .lineLimit(1)
          .truncationMode(.middle)

        HStack(spacing: 8) {
          Text(BuildCacheStorageViewModel.formatBytes(entry.sizeBytes))
            .monospacedDigit()
          Text(lastAccessedText)
          if !entry.existsOnDisk {
            Text("Missing workspace")
              .foregroundStyle(.orange)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      HStack(spacing: 10) {
        Toggle("Keep", isOn: Binding(
          get: { entry.isPinned },
          set: onPinChanged
        ))
        .toggleStyle(.switch)
        .frame(width: 92, alignment: .trailing)
        .help("Exclude from size cleanup")

        Button(action: onReveal) {
          Label("Reveal", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(entry.workspacePath == nil)
        .help("Reveal in Finder")

        Button(role: .destructive, action: onDelete) {
          Label("Delete Cache", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Delete cache")
      }
    }
  }

  private var lastAccessedText: String {
    guard let lastAccessed = entry.lastAccessed else { return "Never accessed" }
    return lastAccessed.formatted(date: .abbreviated, time: .shortened)
  }
}

private struct StorageActionRow: View {
  let title: String
  let description: String
  let systemImage: String
  var isLoading = false
  let isDestructive: Bool
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(role: isDestructive ? .destructive : nil, action: action) {
        if isLoading {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Cleaning Up...")
          }
        } else {
          Label(title, systemImage: systemImage)
        }
      }
      .buttonStyle(.bordered)
      .disabled(isDisabled)

      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct CleanupResultCallout: View {
  let message: String
  let isWarning: Bool
  let actionTitle: String?
  let action: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        .foregroundStyle(isWarning ? .orange : .secondary)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 8) {
        Text(message)
          .font(.caption)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)

        if let actionTitle {
          Button(actionTitle, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(calloutColor.opacity(0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(calloutColor.opacity(0.28), lineWidth: 1)
    )
  }

  private var calloutColor: Color {
    isWarning ? .orange : .secondary
  }
}
