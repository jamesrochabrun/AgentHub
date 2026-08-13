//
//  ContextBuilderPanes.swift
//  AgentHub
//
//  The Context Builder's composable panes: file picker, selected-files list,
//  token budget bar, and the exact assembled-block preview.
//

import AppKit
import SwiftUI

// MARK: - File Picker

struct ContextFilePickerPane: View {
  let viewModel: ContextBuilderViewModel
  @State private var showingTextContentSheet = false

  private var projectName: String {
    (viewModel.projectPath as NSString).lastPathComponent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ContextSourceSectionHeader(
        icon: "folder",
        title: "This Project",
        subtitle: projectName
      )
      searchField
      resultsList

      Divider()
        .padding(.vertical, 2)

      ContextSourceSectionHeader(
        icon: "externaldrive",
        title: "Anywhere on Disk",
        subtitle: "documents, other repos, books"
      )
      addExternalFilesButton
      Text("Added by absolute path. Binary files (PDFs, images) are attached for the agent to read itself.")
        .font(.secondaryCaption)
        .foregroundColor(.secondary.opacity(0.8))
        .fixedSize(horizontal: false, vertical: true)

      Divider()
        .padding(.vertical, 2)

      ContextSourceSectionHeader(
        icon: "text.quote",
        title: "Pasted Text",
        subtitle: "notes, snippets, prompts"
      )
      addTextContentButton
      Text("Stored inside the context set — no file needed.")
        .font(.secondaryCaption)
        .foregroundColor(.secondary.opacity(0.8))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .task(id: viewModel.searchQuery) {
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await viewModel.performSearch()
    }
    .sheet(isPresented: $showingTextContentSheet) {
      ContextTextSnippetSheet { title, content in
        viewModel.addTextSnippet(title: title, content: content)
      }
    }
  }

  private var addTextContentButton: some View {
    Button {
      showingTextContentSheet = true
    } label: {
      Label("Add Text Content…", systemImage: "plus.circle")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .help("Type or paste text — a note, a spec, a prompt — and store it in the context set.")
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
      TextField("Search files in \(projectName)", text: Bindable(viewModel).searchQuery)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  private var resultsList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if viewModel.searchResults.isEmpty && !viewModel.isSearching {
          Text(viewModel.searchQuery.isEmpty
            ? "Recent files in \(projectName) appear here."
            : "No matches in \(projectName).")
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
        }
        ForEach(viewModel.searchResults) { result in
          ContextFilePickerRow(
            result: result,
            isSelected: viewModel.isSelected(relativePath: result.relativePath)
          ) {
            Task { await viewModel.toggleSelection(relativePath: result.relativePath) }
          }
        }
      }
    }
    .frame(maxHeight: .infinity)
  }

  private var addExternalFilesButton: some View {
    Button {
      presentExternalFilePicker()
    } label: {
      Label("Add External Files…", systemImage: "plus.circle")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .help("Select multiple files at once — repeat for files from other locations.")
  }

  /// Deferred to a later run-loop turn — creating NSOpenPanel synchronously
  /// inside a button action can deadlock during GCD queue drain (see
  /// MultiSessionLaunchViewModel.selectRepository).
  private func presentExternalFilePicker() {
    let viewModel = self.viewModel
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      MainActor.assumeIsolated {
        let panel = NSOpenPanel()
        panel.title = "Add External Context Files"
        panel.message = "Pick files from anywhere — you can select many at once"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
          let urls = panel.urls
          Task { await viewModel.addExternalFiles(urls) }
        }
      }
    }
  }
}

// MARK: - Source section header

/// Labels one context source in the picker so the hierarchy — this project's
/// files vs. external files — is visible structure, not implied.
private struct ContextSourceSectionHeader: View {
  let icon: String
  let title: String
  let subtitle: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.secondary)
      Text(title.uppercased())
        .font(.geist(size: 10, weight: .semibold))
        .foregroundColor(.secondary)
        .kerning(0.6)
      Text(subtitle)
        .font(.secondaryCaption)
        .foregroundColor(.secondary.opacity(0.7))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
  }
}

private struct ContextFilePickerRow: View {
  let result: FileSearchResult
  let isSelected: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 6) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 11))
          .foregroundColor(isSelected ? .brandPrimary : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(result.name)
            .font(.system(size: 12))
            .lineLimit(1)
          Text(result.relativePath)
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Selected Files

struct ContextSelectedFilesList: View {
  let viewModel: ContextBuilderViewModel

  private var itemCount: Int {
    viewModel.selectedRows.count + viewModel.textSnippets.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Selected items (\(itemCount))")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
      if itemCount == 0 {
        Text("Pick files on the left, or paste text — everything here is handed to the agent at launch.")
          .font(.secondaryCaption)
          .foregroundColor(.secondary.opacity(0.7))
          .padding(.vertical, 6)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(viewModel.selectedRows) { row in
              ContextSelectedFileRowView(row: row) {
                viewModel.removeSelection(relativePath: row.relativePath)
              }
            }
            ForEach(viewModel.textSnippets) { snippet in
              ContextSnippetRowView(snippet: snippet) {
                viewModel.removeTextSnippet(id: snippet.id)
              }
            }
          }
        }
        .frame(minHeight: 70, maxHeight: 160)
      }
    }
  }
}

private struct ContextSnippetRowView: View {
  let snippet: ContextTextSnippet
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "text.quote")
        .font(.system(size: 10))
        .foregroundColor(.secondary)
      Text(snippet.title)
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .help(String(snippet.content.prefix(400)))
      Text("pasted text")
        .font(.secondaryCaption)
        .foregroundColor(.secondary.opacity(0.7))
      Spacer(minLength: 4)
      Text("~\(SessionMonitorState.formatTokenCount(ContextTokenEstimator().estimatedTokens(forByteCount: snippet.content.utf8.count)))")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Text snippet sheet

/// "Add text content": title + pasted body, stored inside the context set.
struct ContextTextSnippetSheet: View {
  @State private var title = ""
  @State private var content = ""
  @Environment(\.dismiss) private var dismiss
  @Environment(\.runtimeTheme) private var runtimeTheme
  let onAdd: (String, String) -> Void

  private var isValid: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !content.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Add Text Content")
          .font(.primaryDefault)
          .fontWeight(.semibold)
        Spacer()
        Button(action: { dismiss() }) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
      }

      Text("Title")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
      TextField("Name your content", text: $title)
        .textFieldStyle(.roundedBorder)

      Text("Content")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
      ZStack(alignment: .topLeading) {
        if content.isEmpty {
          Text("Type or paste in content…")
            .font(.system(size: 12))
            .foregroundColor(.secondary.opacity(0.6))
            .padding(.leading, 7)
            .padding(.top, 6)
        }
        TextEditor(text: $content)
          .font(.system(size: 12))
          .scrollContentBackground(.hidden)
          .padding(4)
      }
      .frame(minHeight: 220, maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
          .fill(Color(NSColor.controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Add Content") {
          onAdd(title, content)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .tint(Color.brandPrimary(from: runtimeTheme))
        .disabled(!isValid)
      }
    }
    .padding(16)
    .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 440)
  }
}

private struct ContextSelectedFileRowView: View {
  let row: ContextSelectedFileRow
  let onRemove: () -> Void

  private var iconName: String {
    if row.isMissing { return "exclamationmark.triangle" }
    if row.isAttachment { return "paperclip" }
    if row.isExternal { return "arrow.up.right.square" }
    return "doc.text"
  }

  private var displayPath: String {
    row.isExternal ? (row.relativePath as NSString).abbreviatingWithTildeInPath : row.relativePath
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: iconName)
        .font(.system(size: 10))
        .foregroundColor(row.isMissing ? .orange : .secondary)
      Text(displayPath)
        .font(.system(size: 11, design: .monospaced))
        .strikethrough(row.isMissing)
        .foregroundColor(row.isMissing ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.head)
        .help(row.relativePath)
      Spacer(minLength: 4)
      if row.isMissing {
        Text("missing")
          .font(.secondaryCaption)
          .foregroundColor(.orange)
      } else if row.isAttachment {
        Text("attached by path")
          .font(.secondaryCaption)
          .foregroundColor(.secondary)
          .help("Binary or very large — the agent is given the path and reads it with its own tools instead of inlining the contents.")
      } else if let tokens = row.estimatedTokens {
        Text("~\(SessionMonitorState.formatTokenCount(tokens))")
          .font(.secondaryCaption)
          .foregroundColor(.secondary)
      }
      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Token Budget

struct ContextTokenBudgetBar: View {
  let viewModel: ContextBuilderViewModel
  @State private var showingEstimateHelp = false

  private var barColor: Color {
    if viewModel.windowFraction > 0.9 { return .red }
    if viewModel.windowFraction > 0.75 { return .orange }
    return .brandPrimary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(summaryText)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)
        Button {
          showingEstimateHelp.toggle()
        } label: {
          Image(systemName: "questionmark.circle")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingEstimateHelp) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Why is this approximate?")
              .font(.subheadline)
              .fontWeight(.semibold)
            Text("Token counts are estimated from file size (UTF-8 bytes ÷ 4, plus a 15% safety margin), not computed by a real tokenizer. Actual counts vary by model and content — code often tokenizes denser than prose — so estimates deliberately err high. \(windowAssumptionText)")
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(12)
          .frame(width: 280)
        }
        if viewModel.willUseFileFallback {
          Label("will attach as file", systemImage: "doc.badge.arrow.up")
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
            .help("The assembled context exceeds the inline paste limit, so it will be written to a file the agent reads at start.")
        }
        Spacer()
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.gray.opacity(0.2))
          RoundedRectangle(cornerRadius: 2)
            .fill(barColor)
            .frame(width: geometry.size.width * min(viewModel.windowFraction, 1.0))
        }
      }
      .frame(height: 4)
      if viewModel.windowFraction > 0.75 {
        Text("Large context — the agent has less room to work. Nothing is dropped automatically.")
          .font(.secondaryCaption)
          .foregroundColor(.orange)
      }
    }
  }

  private var summaryText: String {
    let total = SessionMonitorState.formatTokenCount(viewModel.totalEstimatedTokens)
    let window = SessionMonitorState.formatTokenCount(viewModel.contextWindowTokens)
    let percent = Int((viewModel.windowFraction * 100).rounded())
    return "~\(total) / \(window) (~\(percent)%) approx."
  }

  private var windowAssumptionText: String {
    let window = SessionMonitorState.formatTokenCount(viewModel.contextWindowTokens)
    if let model = viewModel.modelIdentifier, !model.isEmpty {
      return "The window percentage assumes the \(window)-token context window of “\(model)”, your configured default model."
    }
    return "The window percentage assumes a conservative \(window)-token context window (no default model is configured)."
  }
}

// MARK: - Assembled Preview

struct ContextAssembledPreview: View {
  let viewModel: ContextBuilderViewModel
  @State private var isExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          isExpanded.toggle()
        }
        if isExpanded {
          Task { await viewModel.refreshPreview() }
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
          Text("Preview exact context block")
            .font(.secondaryCaption)
        }
        .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)

      if isExpanded {
        if let fullBytes = viewModel.previewTruncatedByteCount {
          Text("Preview truncated — the full block is \(ByteCountFormatter.string(fromByteCount: Int64(fullBytes), countStyle: .file)) and is assembled in full at launch.")
            .font(.secondaryCaption)
            .foregroundColor(.orange)
        }
        ScrollView {
          Text(viewModel.assembledPreview.isEmpty ? "Nothing selected." : viewModel.assembledPreview)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .frame(minHeight: 140, maxHeight: .infinity)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
        .task(id: viewModel.selectedRows) {
          guard isExpanded else { return }
          await viewModel.refreshPreview()
        }
      }
    }
    .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .top)
  }
}
