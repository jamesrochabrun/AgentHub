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

  @ObservationIgnored private var aiConfigService: (any AIConfigServiceProtocol)?
  @ObservationIgnored
  private var isLoaded = false

  public init() {}

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

  private static func sanitizedCodexApprovalPolicy(_ value: String) -> String {
    switch value {
    case "untrusted", "on-request", "never", "full-auto":
      value
    default:
      ""
    }
  }
}

// MARK: - Claude Config View

struct ClaudeAIConfigView: View {
  @Bindable var viewModel: AIConfigSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      settingsTextField(
        title: "Model",
        placeholder: "CLI default (e.g. opus, sonnet)",
        text: $viewModel.claudeModel,
        onSave: viewModel.saveClaude
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
      settingsTextField(
        title: "Model",
        placeholder: "CLI default (e.g. gpt-5-codex)",
        text: $viewModel.codexModel,
        onSave: viewModel.saveCodex
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
      }

      settingsField("Effort") {
        Picker("", selection: $viewModel.codexReasoningEffort) {
          Text("Default").tag("")
          Text("Low").tag("low")
          Text("Medium").tag("medium")
          Text("High").tag("high")
          Text("XHigh").tag("xhigh")
        }
        .labelsHidden()
        .onChange(of: viewModel.codexReasoningEffort) { viewModel.saveCodex() }
        .frame(maxWidth: 180, alignment: .leading)
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private func settingsTextField(
  title: String,
  placeholder: String,
  text: Binding<String>,
  onSave: @escaping () -> Void
) -> some View {
  settingsField(title) {
    TextField(placeholder, text: text)
      .textFieldStyle(.roundedBorder)
      .onSubmit { onSave() }
      .onChange(of: text.wrappedValue) { onSave() }
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
