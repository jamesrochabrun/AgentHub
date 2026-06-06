//
//  AIConfigSettingsView.swift
//  AgentHub
//
//  Settings UI for configuring AI provider defaults (model, effort, tools, etc.)
//

import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
public final class AIConfigSettingsViewModel {
  var claudeModel: String = ""
  var claudeEffort: String = ""
  var claudeAllowedTools: String = ""
  var claudeDisallowedTools: String = ""

  var codexModel: String = ""
  var codexApprovalPolicy: String = ""
  var codexReasoningEffort: String = ""

  /// Dynamically resolved model options surfaced by the pickers.
  var claudeModels: [AIModelOption] = []
  var codexModels: [AIModelOption] = []

  var codexApprovalPolicyDescription: String {
    Self.codexApprovalPolicyDescription(for: codexApprovalPolicy)
  }

  @ObservationIgnored private var aiConfigService: (any AIConfigServiceProtocol)?
  @ObservationIgnored private let claudeModelCatalog: any ClaudeModelCatalogProviding
  @ObservationIgnored private let codexModelCatalog: any CodexModelCatalogProviding
  @ObservationIgnored
  private var isLoaded = false

  public convenience init() {
    self.init(claudeModelCatalog: ClaudeModelCatalog(), codexModelCatalog: CodexModelCatalog())
  }

  init(
    claudeModelCatalog: any ClaudeModelCatalogProviding,
    codexModelCatalog: any CodexModelCatalogProviding
  ) {
    self.claudeModelCatalog = claudeModelCatalog
    self.codexModelCatalog = codexModelCatalog
  }

  func load(service: (any AIConfigServiceProtocol)?) async {
    guard !isLoaded, let service else { return }
    self.aiConfigService = service
    isLoaded = true

    if let claude = try? await service.getConfig(for: "claude") {
      claudeModel = claude.defaultModel
      claudeEffort = claude.effortLevel
      claudeAllowedTools = claude.allowedTools
      claudeDisallowedTools = claude.disallowedTools
    }
    if let codex = try? await service.getConfig(for: "codex") {
      codexModel = codex.defaultModel
      codexApprovalPolicy = Self.sanitizedCodexApprovalPolicy(codex.approvalPolicy)
      codexReasoningEffort = codex.effortLevel
    }
  }

  func saveClaude() {
    guard let service = aiConfigService else { return }
    let record = AIConfigRecord(
      provider: "claude",
      defaultModel: claudeModel,
      effortLevel: claudeEffort,
      allowedTools: claudeAllowedTools,
      disallowedTools: claudeDisallowedTools
    )
    Task { try? await service.saveConfig(record) }
  }

  func saveCodex() {
    guard let service = aiConfigService else { return }
    let record = AIConfigRecord(
      provider: "codex",
      defaultModel: codexModel,
      effortLevel: codexReasoningEffort,
      approvalPolicy: Self.sanitizedCodexApprovalPolicy(codexApprovalPolicy)
    )
    Task { try? await service.saveConfig(record) }
  }

  /// Refreshes the Claude model options (aliases + ids seen in local history).
  func refreshClaudeModels() async {
    claudeModels = await claudeModelCatalog.availableModels()
  }

  /// Refreshes the Codex model options via `codex debug models` / cache.
  func refreshCodexModels() async {
    codexModels = await codexModelCatalog.availableModels()
  }

  // MARK: Codex effort options (model-aware)

  /// Standard fallback when the selected model reports no reasoning levels.
  static let defaultCodexEfforts: [AIReasoningEffort] = [
    AIReasoningEffort(effort: "low"),
    AIReasoningEffort(effort: "medium"),
    AIReasoningEffort(effort: "high"),
    AIReasoningEffort(effort: "xhigh"),
  ]

  private var selectedCodexModel: AIModelOption? {
    codexModels.first { $0.identifier == codexModel }
  }

  /// Effort levels offered for the currently selected Codex model. Falls back to
  /// the standard set when the model is unknown, and always includes any
  /// already-saved value so the picker can render it.
  var codexEffortOptions: [AIReasoningEffort] {
    let modelEfforts = selectedCodexModel?.reasoningEfforts ?? []
    var efforts = modelEfforts.isEmpty ? Self.defaultCodexEfforts : modelEfforts
    if !codexReasoningEffort.isEmpty, !efforts.contains(where: { $0.effort == codexReasoningEffort }) {
      efforts.append(AIReasoningEffort(effort: codexReasoningEffort))
    }
    return efforts
  }

  /// The selected model's default effort, surfaced in the "Default" option.
  var codexDefaultEffortHint: String? {
    selectedCodexModel?.defaultReasoningEffort
  }

  /// Description of the currently selected effort, when the provider supplied one.
  var codexSelectedEffortDescription: String? {
    codexEffortOptions.first { $0.effort == codexReasoningEffort }?.description
  }

  static func codexEffortLabel(_ effort: String) -> String {
    effort == "xhigh" ? "XHigh" : effort.capitalized
  }

  private static func sanitizedCodexApprovalPolicy(_ value: String) -> String {
    switch value {
    case "untrusted", "on-request", "never", "full-auto":
      value
    default:
      ""
    }
  }

  static func codexApprovalPolicyDescription(for value: String) -> String {
    switch sanitizedCodexApprovalPolicy(value) {
    case "untrusted":
      "Only trusted commands run automatically. Other commands ask before running."
    case "on-request":
      "Codex decides when to ask before running commands."
    case "never":
      "Codex never asks before running commands; failures are returned immediately."
    case "full-auto":
      "Runs with Codex workspace-write sandbox: can edit this workspace, but this is not Full Access."
    default:
      "Uses the installed Codex CLI defaults for approval and sandbox behavior."
    }
  }
}

// MARK: - Claude Config View

struct ClaudeAIConfigView: View {
  @Bindable var viewModel: AIConfigSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      AIModelPickerRow(
        selection: $viewModel.claudeModel,
        options: viewModel.claudeModels,
        customPlaceholder: "CLI default (e.g. opus, sonnet)",
        onCommit: viewModel.saveClaude,
        onRefresh: { Task { await viewModel.refreshClaudeModels() } }
      )

      settingsField("Effort") {
        Picker("", selection: $viewModel.claudeEffort) {
          Text("Default").tag("")
          Text("Low").tag("low")
          Text("Medium").tag("medium")
          Text("High").tag("high")
        }
        .labelsHidden()
        .onChange(of: viewModel.claudeEffort) { viewModel.saveClaude() }
        .frame(maxWidth: 180, alignment: .leading)
      }

      settingsMultilineEditor(
        title: "Allowed Tools",
        placeholder: "One pattern per line or comma-separated, e.g. Bash(npm *)\nRead\nEdit",
        text: $viewModel.claudeAllowedTools,
        onChange: viewModel.saveClaude
      )

      settingsMultilineEditor(
        title: "Denied Tools",
        placeholder: "One pattern per line or comma-separated, e.g. Bash(rm -rf *)",
        text: $viewModel.claudeDisallowedTools,
        onChange: viewModel.saveClaude
      )
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      if viewModel.claudeModels.isEmpty {
        await viewModel.refreshClaudeModels()
      }
    }
  }

  private func settingsMultilineEditor(
    title: String,
    placeholder: String,
    text: Binding<String>,
    onChange: @escaping () -> Void
  ) -> some View {
    settingsField(title) {
      MultilineSettingsEditor(text: text, placeholder: placeholder)
        .onChange(of: text.wrappedValue) { onChange() }
      Text("Use one tool pattern per line, or separate multiple values with commas.")
        .font(.caption2)
        .foregroundColor(.secondary)
    }
  }
}

// MARK: - Codex Config View

struct CodexAIConfigView: View {
  @Bindable var viewModel: AIConfigSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      AIModelPickerRow(
        selection: $viewModel.codexModel,
        options: viewModel.codexModels,
        customPlaceholder: "CLI default (e.g. gpt-5-codex)",
        onCommit: viewModel.saveCodex,
        onRefresh: { Task { await viewModel.refreshCodexModels() } }
      )

      settingsField("Approval") {
        Picker("", selection: $viewModel.codexApprovalPolicy) {
          Text("Default").tag("")
          Text("Untrusted").tag("untrusted")
          Text("On Request").tag("on-request")
          Text("Never").tag("never")
          Text("Full-Auto").tag("full-auto")
        }
        .labelsHidden()
        .onChange(of: viewModel.codexApprovalPolicy) { viewModel.saveCodex() }
        .frame(maxWidth: 220, alignment: .leading)

        Text(viewModel.codexApprovalPolicyDescription)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 420, alignment: .leading)
      }

      settingsField("Effort") {
        Picker("", selection: $viewModel.codexReasoningEffort) {
          Text(viewModel.codexDefaultEffortHint.map { "Default (\($0))" } ?? "Default").tag("")
          ForEach(viewModel.codexEffortOptions) { effort in
            Text(AIConfigSettingsViewModel.codexEffortLabel(effort.effort)).tag(effort.effort)
          }
        }
        .labelsHidden()
        .onChange(of: viewModel.codexReasoningEffort) { viewModel.saveCodex() }
        .frame(maxWidth: 220, alignment: .leading)

        if let description = viewModel.codexSelectedEffortDescription {
          Text(description)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
        }
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      if viewModel.codexModels.isEmpty {
        await viewModel.refreshCodexModels()
      }
    }
  }
}

// MARK: - Model Picker Row

/// A dropdown of dynamically discovered models with a free-text escape hatch so
/// any exact identifier can still be pinned. An empty selection means "CLI
/// default" (AgentHub omits `--model`).
private struct AIModelPickerRow: View {
  @Binding var selection: String
  let options: [AIModelOption]
  let customPlaceholder: String
  let onCommit: () -> Void
  let onRefresh: () -> Void

  var body: some View {
    settingsField("Model") {
      HStack(spacing: 8) {
        Menu {
          Button { select("") } label: {
            menuLabel(name: "Default", isSelected: selection.isEmpty)
          }
          if !options.isEmpty {
            Divider()
            ForEach(options) { option in
              Button { select(option.identifier) } label: {
                menuLabel(name: option.displayName, isSelected: option.identifier == selection)
              }
            }
          }
        } label: {
          menuButtonLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 280, alignment: .leading)

        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .help("Refresh available models")
      }

      // `.labelsHidden()` keeps the grouped Form from promoting the placeholder
      // into a wrapping leading label (which pushed the field off to the right).
      TextField(customPlaceholder, text: $selection)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .onSubmit { onCommit() }
        .onChange(of: selection) { onCommit() }
        .frame(maxWidth: 320, alignment: .leading)

      Text(footnote)
        .font(.caption2)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420, alignment: .leading)
    }
  }

  private func select(_ identifier: String) {
    guard identifier != selection else { return }
    selection = identifier
  }

  private var selectedOption: AIModelOption? {
    options.first { $0.identifier == selection }
  }

  private var footnote: String {
    if let detail = selectedOption?.detail, !detail.isEmpty {
      return detail
    }
    return "Pick a detected model, or type any exact identifier."
  }

  private var menuButtonLabel: some View {
    HStack(spacing: 6) {
      Text(selection.isEmpty ? "Default" : (selectedOption?.displayName ?? selection))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Image(systemName: "chevron.up.chevron.down")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func menuLabel(name: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(name, systemImage: "checkmark")
    } else {
      Text(name)
    }
  }
}

private func settingsField<Content: View>(
  _ title: String,
  @ViewBuilder content: () -> Content
) -> some View {
  VStack(alignment: .leading, spacing: 6) {
    Text(title)
      .font(.caption)
      .foregroundColor(.secondary)
    content()
  }
  .frame(maxWidth: .infinity, alignment: .leading)
}

private struct MultilineSettingsEditor: View {
  @Binding var text: String
  let placeholder: String
  @FocusState private var isFocused: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $text)
        .scrollContentBackground(.hidden)
        .focused($isFocused)
        .font(.system(size: 13))
        .frame(minHeight: 84)
        .padding(6)

      if text.isEmpty {
        Text(placeholder)
          .font(.system(size: 13))
          .foregroundColor(.secondary)
          .padding(.horizontal, 11)
          .padding(.vertical, 14)
          .allowsHitTesting(false)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.textBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isFocused ? Color.accentColor.opacity(0.55) : Color(NSColor.separatorColor), lineWidth: 1)
    )
  }
}
