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

  private var aiConfigService: AIConfigService?
  private var isLoaded = false

  public init() {}

  func load(service: AIConfigService?) async {
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
      codexApprovalPolicy = codex.approvalPolicy
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
      approvalPolicy: codexApprovalPolicy
    )
    Task { try? await service.saveConfig(record) }
  }
}

// MARK: - Claude Config View

struct ClaudeAIConfigView: View {
  @Bindable var viewModel: AIConfigSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Model:")
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .trailing)
        TextField("CLI default (e.g. opus, sonnet)", text: $viewModel.claudeModel)
          .textFieldStyle(.roundedBorder)
          .onSubmit { viewModel.saveClaude() }
          .onChange(of: viewModel.claudeModel) { viewModel.saveClaude() }
      }

      HStack {
        Text("Effort:")
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .trailing)
        Picker("", selection: $viewModel.claudeEffort) {
          Text("Default").tag("")
          Text("Low").tag("low")
          Text("Medium").tag("medium")
          Text("High").tag("high")
        }
        .labelsHidden()
        .onChange(of: viewModel.claudeEffort) { viewModel.saveClaude() }
      }

      HStack(alignment: .top) {
        Text("Allowed:")
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .trailing)
        TextField("e.g. Bash(npm *), Read, Edit", text: $viewModel.claudeAllowedTools)
          .textFieldStyle(.roundedBorder)
          .onSubmit { viewModel.saveClaude() }
          .onChange(of: viewModel.claudeAllowedTools) { viewModel.saveClaude() }
      }

      HStack(alignment: .top) {
        Text("Denied:")
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .trailing)
        TextField("e.g. Bash(rm -rf *)", text: $viewModel.claudeDisallowedTools)
          .textFieldStyle(.roundedBorder)
          .onSubmit { viewModel.saveClaude() }
          .onChange(of: viewModel.claudeDisallowedTools) { viewModel.saveClaude() }
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Codex Config View

struct CodexAIConfigView: View {
  @Bindable var viewModel: AIConfigSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Model:")
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .trailing)
        TextField("CLI default (e.g. gpt-5-codex)", text: $viewModel.codexModel)
          .textFieldStyle(.roundedBorder)
          .onSubmit { viewModel.saveCodex() }
          .onChange(of: viewModel.codexModel) { viewModel.saveCodex() }
      }

      HStack {
        Text("Approval:")
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .trailing)
        Picker("", selection: $viewModel.codexApprovalPolicy) {
          Text("Default").tag("")
          Text("Suggest").tag("suggest")
          Text("Auto-Edit").tag("auto-edit")
          Text("Full-Auto").tag("full-auto")
        }
        .labelsHidden()
        .onChange(of: viewModel.codexApprovalPolicy) { viewModel.saveCodex() }
      }

      HStack {
        Text("Effort:")
          .foregroundColor(.secondary)
          .frame(width: 80, alignment: .trailing)
        Picker("", selection: $viewModel.codexReasoningEffort) {
          Text("Default").tag("")
          Text("Low").tag("low")
          Text("Medium").tag("medium")
          Text("High").tag("high")
        }
        .labelsHidden()
        .onChange(of: viewModel.codexReasoningEffort) { viewModel.saveCodex() }
      }
    }
    .padding(.vertical, 4)
  }
}
