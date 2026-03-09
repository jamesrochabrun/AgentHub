//
//  QuickFilePickerView.swift
//  AgentHub
//
//  Cmd+Shift+P modal for fuzzy file search within a project.
//

import SwiftUI

// MARK: - QuickFilePickerView

public struct QuickFilePickerView: View {
  @Binding var isPresented: Bool
  let projectPath: String
  let onFileSelected: (String) -> Void

  @State private var searchQuery = ""
  @State private var results: [FileSearchResult] = []
  @State private var selectedIndex = 0
  @State private var showingRecent = true
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
                QuickFileResultRow(result: result, isSelected: index == selectedIndex)
                  .id(index)
                  .contentShape(Rectangle())
                  .onTapGesture { selectItem(at: index) }
              }
            }
          }
          .frame(maxHeight: 320)
          .onChange(of: selectedIndex) { _, newIndex in
            withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
          }
        }
      } else if !searchQuery.isEmpty {
        Divider()
        VStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 20))
            .foregroundColor(.secondary.opacity(0.5))
          Text("No files found for \"\(searchQuery)\"")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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
      }
    }
    .frame(width: 580)
    .onAppear {
      isSearchFocused = true
    }
    .task(id: searchQuery) {
      // Automatically cancels previous task when searchQuery changes
      if searchQuery.isEmpty {
        let recent = await FileIndexService.shared.recentFiles(in: projectPath)
        results = recent
        showingRecent = true
        selectedIndex = 0
        return
      }
      showingRecent = false
      // Debounce — but clear results immediately to avoid showing stale data
      results = []
      selectedIndex = 0
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      let found = await FileIndexService.shared.search(query: searchQuery, in: projectPath)
      guard !Task.isCancelled else { return }
      results = found
      selectedIndex = 0
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
