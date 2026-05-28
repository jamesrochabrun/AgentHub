//
//  QuickFilePickerView.swift
//  AgentHub
//
//  Cmd+P modal for Spotlight-backed file search within a project.
//

import Foundation
import SwiftUI

private let quickFileSearchStateAnimation = Animation.easeInOut(duration: 0.18)

private enum QuickFileSearchPhase: Equatable {
  case idle
  case preparing
  case checkingSpotlight(fallbackStatus: FileSearchIndexStatus)
  case warmingLocalIndex
  case stillWorking

  var title: String {
    switch self {
    case .idle: return ""
    case .preparing: return "Preparing search"
    case .checkingSpotlight: return "Checking Spotlight index"
    case .warmingLocalIndex: return "Warming local file index"
    case .stillWorking: return "Still searching"
    }
  }

  var detail: String {
    switch self {
    case .idle:
      return ""
    case .preparing:
      return "Debouncing input before querying the project."
    case .checkingSpotlight(let fallbackStatus):
      switch fallbackStatus {
      case .ready:
        return "Local fallback is ready if Spotlight has no indexed match."
      case .building:
        return "AgentHub is also building a local fallback for unindexed files."
      case .idle:
        return "AgentHub will build a local fallback if Spotlight has no indexed match."
      }
    case .warmingLocalIndex:
      return "Spotlight is taking longer than usual; the local scanner is catching up."
    case .stillWorking:
      return "Large repositories can take longer while Spotlight and the local fallback catch up."
    }
  }

  var spotlightStep: QuickFileSearchStepState {
    switch self {
    case .idle, .preparing:
      return .queued
    case .checkingSpotlight, .warmingLocalIndex, .stillWorking:
      return .active
    }
  }

  var localIndexStep: QuickFileSearchStepState {
    switch self {
    case .idle, .preparing:
      return .queued
    case .checkingSpotlight(let fallbackStatus):
      switch fallbackStatus {
      case .ready:
        return .complete
      case .building:
        return .active
      case .idle:
        return .queued
      }
    case .warmingLocalIndex, .stillWorking:
      return .active
    }
  }
}

private enum QuickFileSearchStepState {
  case queued
  case active
  case complete
}

// MARK: - QuickFilePickerView

public struct QuickFilePickerView: View {
  @Binding var isPresented: Bool
  let projectPath: String
  let onFileSelected: (String) -> Void

  @State private var searchQuery = ""
  @State private var results: [FileSearchResult] = []
  @State private var selectedIndex = 0
  @State private var showingRecent = true
  @State private var isIndexing = false
  @State private var searchPhase: QuickFileSearchPhase = .idle
  @State private var lastSearchDiagnostics: FileSearchDiagnostics?
  @FocusState private var isSearchFocused: Bool

  public init(
    isPresented: Binding<Bool>,
    projectPath: String,
    onFileSelected: @escaping (String) -> Void
  ) {
    self._isPresented = isPresented
    self.projectPath = projectPath
    self.onFileSelected = onFileSelected
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Search field
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 16))
          .foregroundColor(.secondary)

        TextField("Go to file...", text: $searchQuery)
          .textFieldStyle(.plain)
          .font(.system(size: 16))
          .focused($isSearchFocused)
          .onSubmit { selectCurrentItem() }

        if !searchQuery.isEmpty {
          Button(action: { searchQuery = "" }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }

        Spacer()

        Text("esc")
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.secondary.opacity(0.6))
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(Color.secondary.opacity(0.12))
          )
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      if !results.isEmpty {
        Divider()

        if showingRecent {
          HStack {
            Text("Recently Opened")
              .font(.system(size: 11, weight: .medium))
              .foregroundColor(.secondary)
            Spacer()
          }
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 4)
        }

        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                Button(action: { selectItem(at: index) }) {
                  QuickFileResultRow(result: result, isSelected: index == selectedIndex)
                }
                .buttonStyle(.plain)
                .id(index)
              }
            }
          }
          .frame(maxHeight: min(CGFloat(results.count) * 48 + 4, 440))
          .onChange(of: selectedIndex) { _, newIndex in
            withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
          }
        }

        if shouldShowSearchDiagnostics {
          Divider()
          QuickFileSearchDiagnosticsFooter(diagnostics: lastSearchDiagnostics)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      } else if isIndexing && !searchQuery.isEmpty {
        Divider()
        QuickFileSearchProgressView(phase: searchPhase)
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
      } else if !searchQuery.isEmpty {
        Divider()
        VStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 20))
            .foregroundColor(.secondary.opacity(0.5))
          Text("No files found for \"\(searchQuery)\"")
            .font(.caption)
            .foregroundColor(.secondary)
          if lastSearchDiagnostics?.source == .localIndex {
            Text("Spotlight returned no indexed matches; local index scanned \(lastSearchDiagnostics?.localIndexedFileCount ?? 0) files.")
              .font(.caption2)
              .foregroundColor(.secondary.opacity(0.7))
              .multilineTextAlignment(.center)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .transition(.opacity)
      } else if results.isEmpty {
        Divider()
        VStack(spacing: 6) {
          Image(systemName: "clock")
            .font(.system(size: 20))
            .foregroundColor(.secondary.opacity(0.5))
          Text("No recently opened files")
            .font(.caption)
            .foregroundColor(.secondary)
          Text("Start typing to search")
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .transition(.opacity)
      }
    }
    .animation(quickFileSearchStateAnimation, value: isIndexing)
    .animation(quickFileSearchStateAnimation, value: results.isEmpty)
    .animation(quickFileSearchStateAnimation, value: searchPhase)
    .animation(quickFileSearchStateAnimation, value: shouldShowSearchDiagnostics)
    .frame(width: 580)
    .fixedSize(horizontal: false, vertical: true)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, 50)
    .padding(.top, 140)
    .padding(.bottom, 50)
    .onAppear {
      isSearchFocused = true
      // @FocusState doesn't work in borderless NSPanel — force focus via AppKit
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard let window = NSApp.keyWindow else { return }
        func findTextField(in view: NSView) -> NSTextField? {
          if let tf = view as? NSTextField, tf.isEditable { return tf }
          for sub in view.subviews {
            if let found = findTextField(in: sub) { return found }
          }
          return nil
        }
        if let contentView = window.contentView,
           let textField = findTextField(in: contentView) {
          window.makeFirstResponder(textField)
        }
      }
    }
    .task(id: searchQuery) {
      // Automatically cancels previous task when searchQuery changes
      if searchQuery.isEmpty {
        withAnimation(quickFileSearchStateAnimation) {
          isIndexing = false
          searchPhase = .idle
          lastSearchDiagnostics = nil
        }
        let recent = await FileIndexService.shared.recentFiles(in: projectPath)
        withAnimation(quickFileSearchStateAnimation) {
          results = recent
          showingRecent = true
          selectedIndex = 0
        }
        return
      }
      withAnimation(quickFileSearchStateAnimation) {
        showingRecent = false
        // Debounce — but clear results immediately to avoid showing stale data
        results = []
        lastSearchDiagnostics = nil
        selectedIndex = 0
        isIndexing = false
        searchPhase = .preparing
      }
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      let fallbackStatus = await FileIndexService.shared.searchIndexStatus(projectPath: projectPath)
      guard !Task.isCancelled else { return }
      withAnimation(quickFileSearchStateAnimation) {
        isIndexing = true
        searchPhase = .checkingSpotlight(fallbackStatus: fallbackStatus)
      }
      let diagnostics = await FileIndexService.shared.searchWithDiagnostics(query: searchQuery, in: projectPath)
      guard !Task.isCancelled else { return }
      withAnimation(quickFileSearchStateAnimation) {
        isIndexing = false
        lastSearchDiagnostics = diagnostics
        results = diagnostics.results
        selectedIndex = 0
      }
    }
    .task(id: isIndexing) {
      guard isIndexing, !searchQuery.isEmpty else { return }

      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled, isIndexing else { return }
      let fallbackStatus = await FileIndexService.shared.searchIndexStatus(projectPath: projectPath)
      guard !Task.isCancelled, isIndexing else { return }
      withAnimation(quickFileSearchStateAnimation) {
        searchPhase = fallbackStatus == .ready
          ? .checkingSpotlight(fallbackStatus: .ready)
          : .warmingLocalIndex
      }

      try? await Task.sleep(for: .milliseconds(1200))
      guard !Task.isCancelled, isIndexing else { return }
      withAnimation(quickFileSearchStateAnimation) {
        searchPhase = .stillWorking
      }
    }
    .onKeyPress(.upArrow) {
      selectedIndex = max(0, selectedIndex - 1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      guard !results.isEmpty else { return .handled }
      selectedIndex = min(results.count - 1, selectedIndex + 1)
      return .handled
    }
    .onKeyPress(.escape) {
      isPresented = false
      return .handled
    }
    .onExitCommand {
      isPresented = false
    }
  }

  // MARK: - Selection

  private func selectCurrentItem() {
    guard !results.isEmpty else { return }
    selectItem(at: selectedIndex)
  }

  private func selectItem(at index: Int) {
    guard index < results.count else { return }
    isPresented = false
    onFileSelected(results[index].absolutePath)
  }

  private var shouldShowSearchDiagnostics: Bool {
    guard !showingRecent,
          let lastSearchDiagnostics,
          !searchQuery.isEmpty else {
      return false
    }

    return lastSearchDiagnostics.source == .localIndex ||
      lastSearchDiagnostics.spotlightElapsedSeconds >= 0.75
  }
}

// MARK: - QuickFileSearchProgressView

private struct QuickFileSearchProgressView: View {
  let phase: QuickFileSearchPhase

  var body: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)

      VStack(spacing: 4) {
        Text(phase.title)
          .font(.caption)
          .foregroundColor(.primary)
        Text(phase.detail)
          .font(.caption2)
          .foregroundColor(.secondary.opacity(0.75))
          .multilineTextAlignment(.center)
      }

      HStack(spacing: 8) {
        QuickFileSearchProgressStep(
          title: "Spotlight",
          systemImage: "magnifyingglass",
          state: phase.spotlightStep
        )
        QuickFileSearchProgressStep(
          title: "Local index",
          systemImage: "folder.badge.gearshape",
          state: phase.localIndexStep
        )
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.vertical, 20)
  }
}

private struct QuickFileSearchProgressStep: View {
  let title: String
  let systemImage: String
  let state: QuickFileSearchStepState

  private var iconName: String {
    switch state {
    case .queued: return systemImage
    case .active: return "clock.arrow.circlepath"
    case .complete: return "checkmark.circle.fill"
    }
  }

  private var foregroundStyle: Color {
    switch state {
    case .queued: return .secondary
    case .active: return .accentColor
    case .complete: return .accentColor
    }
  }

  private var statusText: String {
    switch state {
    case .queued: return "Queued"
    case .active: return "Active"
    case .complete: return "Ready"
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: iconName)
        .foregroundColor(foregroundStyle)
        .accessibilityHidden(true)
        .id(iconName)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundColor(.primary)
        Text(statusText)
          .font(.caption2)
          .foregroundColor(.secondary)
          .contentTransition(.opacity)
      }
      .lineLimit(1)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity)
    .background(Color.primary.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .animation(quickFileSearchStateAnimation, value: state)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - QuickFileSearchDiagnosticsFooter

private struct QuickFileSearchDiagnosticsFooter: View {
  let diagnostics: FileSearchDiagnostics?

  @ViewBuilder
  var body: some View {
    if let diagnostics {
      HStack(spacing: 8) {
        Image(systemName: iconName(for: diagnostics))
          .font(.caption)
          .foregroundColor(.secondary)
          .accessibilityHidden(true)

        Text(message(for: diagnostics))
          .font(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(2)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Color.primary.opacity(0.035))
    }
  }

  private func iconName(for diagnostics: FileSearchDiagnostics) -> String {
    diagnostics.source == .localIndex ? "folder.badge.gearshape" : "magnifyingglass"
  }

  private func message(for diagnostics: FileSearchDiagnostics) -> String {
    switch diagnostics.source {
    case .localIndex:
      return "Using local index. Spotlight returned \(diagnostics.spotlightCandidateCount) indexed candidates in \(formattedDuration(diagnostics.spotlightElapsedSeconds)); scanned \(diagnostics.localIndexedFileCount) files."
    case .spotlight:
      return "Spotlight returned \(diagnostics.spotlightCandidateCount) indexed candidates in \(formattedDuration(diagnostics.spotlightElapsedSeconds))."
    }
  }

  private func formattedDuration(_ seconds: TimeInterval) -> String {
    if seconds < 1 {
      return "\(Int((seconds * 1000).rounded()))ms"
    }

    return String(format: "%.1fs", seconds)
  }
}

// MARK: - QuickFileResultRow

private struct QuickFileResultRow: View {
  let result: FileSearchResult
  let isSelected: Bool

  @State private var isHovered = false

  private var rowBackground: Color {
    if isSelected { return Color.accentColor }
    if isHovered { return Color.primary.opacity(0.08) }
    return Color.clear
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: fileIcon(for: result.name))
        .font(.system(size: 16))
        .foregroundColor(isSelected ? .white : fileIconColor(for: result.name))
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 2) {
        Text(result.name)
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(isSelected ? .white : .primary)
          .lineLimit(1)

        Text(result.relativePath)
          .font(.caption)
          .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
          .lineLimit(1)
      }

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(rowBackground)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }

  private func fileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":                    return "swift"
    case "js", "jsx":                return "chevron.left.forwardslash.chevron.right"
    case "ts", "tsx":                return "chevron.left.forwardslash.chevron.right"
    case "md", "markdown":           return "doc.richtext"
    case "json":                     return "curlybraces"
    case "yaml", "yml":              return "list.bullet.indent"
    case "html", "htm":              return "globe"
    case "css", "scss", "sass":      return "paintbrush"
    case "sh", "bash", "zsh":        return "terminal"
    case "py":                       return "chevron.left.forwardslash.chevron.right"
    case "png", "jpg", "jpeg", "gif", "svg": return "photo"
    default:                         return "doc.text"
    }
  }

  private func fileIconColor(for name: String) -> Color {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":                    return .orange
    case "js", "jsx":                return .yellow
    case "ts", "tsx":                return .blue
    case "json":                     return .green
    case "md", "markdown":           return .secondary
    case "html", "htm":              return .orange
    case "css", "scss", "sass":      return .purple
    case "sh", "bash", "zsh":        return .green
    case "yaml", "yml":              return .mint
    case "py":                       return .blue
    default:                         return .secondary
    }
  }
}
