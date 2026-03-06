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
  @State private var searchTask: Task<Void, Never>?
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
    ZStack {
      Color.black.opacity(0.4)
        .ignoresSafeArea()
        .onTapGesture { isPresented = false }

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
            .frame(maxHeight: 300)
            .onChange(of: selectedIndex) { _, newIndex in
              withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
            }
          }
        } else if !searchQuery.isEmpty {
          Divider()
          Text("No files found")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding()
        }
      }
      .background(.regularMaterial)
      .cornerRadius(12)
      .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
      .frame(width: 600)
      .padding(.top, 100)
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .onAppear {
      isSearchFocused = true
      Task { await performSearch() }
    }
    .onDisappear {
      searchTask?.cancel()
    }
    .onChange(of: searchQuery) { _, _ in
      selectedIndex = 0
      scheduleSearch()
    }
    .onKeyPress(.upArrow) {
      selectedIndex = max(0, selectedIndex - 1)
      return .handled
    }
    .onKeyPress(.downArrow) {
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

  // MARK: - Search

  private func scheduleSearch() {
    searchTask?.cancel()
    searchTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await performSearch()
    }
  }

  private func performSearch() async {
    results = await FileIndexService.shared.search(query: searchQuery, in: projectPath)
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

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: fileIcon(for: result.name))
        .font(.system(size: 16))
        .foregroundColor(isSelected ? .white : .secondary)
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
    .background(isSelected ? Color.accentColor : Color.clear)
    .contentShape(Rectangle())
  }

  private func fileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift":
      return "swift"
    case "md":
      return "doc.richtext"
    case "json":
      return "curlybraces"
    case "yaml", "yml":
      return "doc.plaintext"
    case "png", "jpg", "jpeg", "gif", "svg":
      return "photo"
    default:
      return "doc"
    }
  }
}
