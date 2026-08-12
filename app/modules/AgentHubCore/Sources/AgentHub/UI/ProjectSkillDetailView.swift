//
//  ProjectSkillDetailView.swift
//  AgentHub
//
//  Detail page for a skill inside the Project Details panel: a file list for
//  the skill's bundle on the left, and the selected file rendered on the
//  right — markdown through the same MarkdownCardView the plan view uses.
//

import SwiftUI

struct ProjectSkillDetailView: View {
  let skill: ProjectAgentSkill
  let onBack: () -> Void

  @State private var files: [SkillBundleFile] = []
  @State private var selectedFile: SkillBundleFile?
  @State private var fileContent: String?
  @State private var isLoadingContent = true

  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      backBar
        .padding(.horizontal, 20)
        .padding(.vertical, 12)

      HStack(alignment: .top, spacing: 14) {
        fileList
          .frame(width: 190)

        contentPane
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .task(id: skill.id) {
      await loadFiles()
    }
    .task(id: selectedFile?.id) {
      await loadSelectedFileContent()
    }
  }

  // MARK: Back bar

  private var backBar: some View {
    Button(action: onBack) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.left")
          .font(.system(size: 11, weight: .semibold))
        Text("Back to skills")
          .font(.secondaryDefault)
      }
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.leftArrow, modifiers: [.command])
    .help("Back to skills")
  }

  // MARK: File list

  private var fileList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(files) { file in
          fileRow(file)
        }
      }
    }
  }

  private func fileRow(_ file: SkillBundleFile) -> some View {
    let isSelected = file.id == selectedFile?.id
    return Button {
      selectedFile = file
    } label: {
      Text(file.relativePath)
        .font(.primarySmall)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.surfaceElevated : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(
              isSelected
                ? Color.brandPrimary(from: runtimeTheme).opacity(0.4)
                : Color.clear,
              lineWidth: 1
            )
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: Content pane

  private var contentPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        skillHeader

        Divider()

        if isLoadingContent {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else if let fileContent {
          if selectedFile?.isMarkdown == true {
            MarkdownCardView(content: markdownBody(fileContent), transparent: true)
          } else {
            Text(fileContent)
              .font(.primarySmall)
              .foregroundStyle(.primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          Text("Could not read this file.")
            .font(.secondarySmall)
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.surfaceOverlay.opacity(0.4))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    )
  }

  private var skillHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      ProjectAssetCardIcon(systemImage: "sparkles")

      VStack(alignment: .leading, spacing: 5) {
        Text(skill.name)
          .font(.primaryLarge)
          .foregroundStyle(.primary)

        if !skill.skillDescription.isEmpty {
          Text(skill.skillDescription)
            .font(.secondarySmall)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 6) {
          ProjectAssetScopeBadge(scope: skill.scope)
          ProjectAssetProviderBadges(providers: skill.providers)
        }
      }

      Spacer(minLength: 0)
    }
  }

  /// Renders the body without the YAML frontmatter block — name and
  /// description are already in the header above.
  private func markdownBody(_ content: String) -> String {
    let lines = content.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }
    guard let closingIndex = lines.dropFirst().firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces) == "---"
    }) else {
      return content
    }
    return lines[(closingIndex + 1)...].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Loading

  private func loadFiles() async {
    let directoryPath = skill.directoryPath
    guard !directoryPath.isEmpty else {
      files = []
      selectedFile = nil
      return
    }
    let loaded = await Task.detached(priority: .utility) {
      SkillBundleFile.files(inSkillDirectory: directoryPath)
    }.value
    files = loaded
    selectedFile = loaded.first
  }

  private func loadSelectedFileContent() async {
    guard let selectedFile else {
      fileContent = nil
      isLoadingContent = false
      return
    }
    isLoadingContent = true
    let path = selectedFile.path
    fileContent = await Task.detached(priority: .utility) {
      try? String(contentsOfFile: path, encoding: .utf8)
    }.value
    isLoadingContent = false
  }
}

// MARK: - ProjectRuleDetailView

/// Inline reader for a rules file (CLAUDE.md, AGENTS.md, `.rules`), same
/// pattern as the skill detail: back bar, header, then the file rendered as
/// markdown (or monospace for non-markdown files).
struct ProjectRuleDetailView: View {
  let rule: ProjectAgentRule
  let onBack: () -> Void

  @State private var fileContent: String?
  @State private var isLoadingContent = true

  private var isMarkdown: Bool {
    let ext = (rule.path as NSString).pathExtension.lowercased()
    return ext == "md" || ext == "markdown"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      backBar
        .padding(.horizontal, 20)
        .padding(.vertical, 12)

      contentPane
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
    .task(id: rule.id) {
      await loadContent()
    }
  }

  private var backBar: some View {
    Button(action: onBack) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.left")
          .font(.system(size: 11, weight: .semibold))
        Text("Back to rules")
          .font(.secondaryDefault)
      }
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.leftArrow, modifiers: [.command])
    .help("Back to rules")
  }

  private var contentPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ruleHeader

        Divider()

        if isLoadingContent {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        } else if let fileContent {
          if isMarkdown {
            MarkdownCardView(content: fileContent, transparent: true)
          } else {
            Text(fileContent)
              .font(.primarySmall)
              .foregroundStyle(.primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          Text("Could not read this file.")
            .font(.secondarySmall)
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.surfaceOverlay.opacity(0.4))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    )
  }

  private var ruleHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      ProjectAssetCardIcon(systemImage: "list.bullet.rectangle")

      VStack(alignment: .leading, spacing: 5) {
        Text(rule.title)
          .font(.primaryLarge)
          .foregroundStyle(.primary)

        Text((rule.path as NSString).abbreviatingWithTildeInPath)
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        HStack(spacing: 6) {
          ProjectAssetScopeBadge(scope: rule.scope)
          ProjectAssetProviderBadges(providers: rule.providers)
          ProjectAssetBadge(text: "\(rule.lineCount) lines")
        }
      }

      Spacer(minLength: 8)

      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: rule.path))
      } label: {
        Image(systemName: "arrow.up.forward.square")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open in default editor")
    }
  }

  private func loadContent() async {
    isLoadingContent = true
    let path = rule.path
    fileContent = await Task.detached(priority: .utility) {
      try? String(contentsOfFile: path, encoding: .utf8)
    }.value
    isLoadingContent = false
  }
}

// MARK: - SkillBundleFile

struct SkillBundleFile: Identifiable, Equatable, Sendable {
  var id: String { path }
  let path: String
  let relativePath: String

  var isMarkdown: Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ext == "md" || ext == "markdown"
  }

  /// All regular files in the skill directory, SKILL.md first, the rest
  /// sorted by relative path.
  static func files(inSkillDirectory directoryPath: String) -> [SkillBundleFile] {
    let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
      return []
    }

    var results: [SkillBundleFile] = []
    for case let file as URL in enumerator {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      let relative = String(file.path.dropFirst(directoryURL.path.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      results.append(SkillBundleFile(path: file.path, relativePath: relative))
    }

    return results.sorted { lhs, rhs in
      if lhs.relativePath == "SKILL.md" { return true }
      if rhs.relativePath == "SKILL.md" { return false }
      return lhs.relativePath < rhs.relativePath
    }
  }
}
