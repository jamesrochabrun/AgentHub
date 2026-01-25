//
//  ToolApprovalSheet.swift
//  AgentHub
//
//  Sheet for approving or denying tool use requests in headless mode.
//

import SwiftUI

// MARK: - ToolApprovalSheet

/// Sheet presented when Claude requests permission to use a tool.
///
/// Displays the tool name, arguments, and provides Approve/Deny buttons.
/// Used in headless mode when `permission-prompt-tool stdio` sends a
/// control_request event.
///
/// ## Design
/// Follows the Steve Jobs design bar:
/// - One clear primary action (Approve button is prominent)
/// - Ruthless simplicity (tool name + arguments, two buttons)
/// - Native macOS feel (system colors, standard sheet presentation)
public struct ToolApprovalSheet: View {
  /// The control request event from Claude
  let controlRequest: ClaudeControlRequestEvent

  /// Callback when user approves the tool use
  let onApprove: () -> Void

  /// Callback when user denies the tool use
  let onDeny: () -> Void

  /// Dismiss action for the sheet
  @Environment(\.dismiss) private var dismiss

  /// Creates a new tool approval sheet.
  /// - Parameters:
  ///   - controlRequest: The control request event containing tool details
  ///   - onApprove: Callback invoked when user approves
  ///   - onDeny: Callback invoked when user denies
  public init(
    controlRequest: ClaudeControlRequestEvent,
    onApprove: @escaping () -> Void,
    onDeny: @escaping () -> Void
  ) {
    self.controlRequest = controlRequest
    self.onApprove = onApprove
    self.onDeny = onDeny
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      Divider()

      // Content
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          toolInfoSection
          argumentsSection
        }
        .padding(20)
      }

      Divider()

      // Actions
      actionButtons
    }
    .frame(width: 480, height: 400)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      // Warning icon
      Image(systemName: "hand.raised.fill")
        .font(.system(size: 24))
        .foregroundColor(Color.Chat.toolUse)

      VStack(alignment: .leading, spacing: 2) {
        Text("Tool Permission Required")
          .font(.headline)
          .foregroundColor(.primary)

        Text("Claude wants to use a tool")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }

      Spacer()
    }
    .padding(16)
    .background(Color.Chat.toolUse.opacity(0.08))
  }

  // MARK: - Tool Info

  private var toolInfoSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Tool")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
        .textCase(.uppercase)

      HStack(spacing: 8) {
        Image(systemName: toolIcon)
          .font(.system(size: 16))
          .foregroundColor(Color.Chat.toolUse)

        Text(toolName)
          .font(.system(.body, design: .monospaced, weight: .medium))
          .foregroundColor(.primary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
    }
  }

  // MARK: - Arguments

  private var argumentsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Arguments")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
        .textCase(.uppercase)

      ScrollView(.horizontal, showsIndicators: false) {
        Text(formattedArguments)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.primary)
          .textSelection(.enabled)
          .padding(12)
      }
      .frame(maxWidth: .infinity, maxHeight: 180, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
    }
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack(spacing: 12) {
      // Deny button (secondary)
      Button(action: handleDeny) {
        HStack(spacing: 6) {
          Image(systemName: "xmark.circle")
          Text("Deny")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .keyboardShortcut(.escape, modifiers: [])

      // Approve button (primary)
      Button(action: handleApprove) {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
          Text("Approve")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color.Chat.toolResult)
      .controlSize(.large)
      .keyboardShortcut(.return, modifiers: [])
    }
    .padding(16)
  }

  // MARK: - Computed Properties

  private var toolName: String {
    switch controlRequest.request {
    case .canUseTool(let name, _, _):
      return name
    case .hookCallback(let callbackId, _):
      return "Hook: \(callbackId)"
    case .unknown:
      return "Unknown"
    }
  }

  private var toolIcon: String {
    let name = toolName.lowercased()

    switch name {
    case "bash":
      return "terminal"
    case "read":
      return "doc.text"
    case "write":
      return "square.and.pencil"
    case "edit":
      return "pencil"
    case "glob":
      return "folder.badge.gearshape"
    case "grep":
      return "magnifyingglass"
    case "webfetch":
      return "globe"
    case "websearch":
      return "magnifyingglass.circle"
    default:
      return "gearshape"
    }
  }

  private var formattedArguments: String {
    switch controlRequest.request {
    case .canUseTool(_, let input, _):
      return formatJSONValue(input)
    case .hookCallback(_, let input):
      return formatJSONValue(input)
    case .unknown:
      return "No arguments available"
    }
  }

  private func formatJSONValue(_ value: JSONValue) -> String {
    // Try to pretty-print the JSON
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    if let data = try? encoder.encode(value),
       let string = String(data: data, encoding: .utf8) {
      return string
    }

    // Fallback to basic description
    if let dict = value.dictionary {
      return dict.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    return String(describing: value.value)
  }

  // MARK: - Actions

  private func handleApprove() {
    onApprove()
    dismiss()
  }

  private func handleDeny() {
    onDeny()
    dismiss()
  }
}

// MARK: - Preview

#Preview("Bash Command") {
  ToolApprovalSheet(
    controlRequest: ClaudeControlRequestEvent(
      requestId: "req-123",
      request: .canUseTool(
        toolName: "Bash",
        input: JSONValue([
          "command": "rm -rf /tmp/old-files"
        ]),
        toolUseId: "tool-456"
      )
    ),
    onApprove: { print("Approved") },
    onDeny: { print("Denied") }
  )
}

#Preview("File Edit") {
  ToolApprovalSheet(
    controlRequest: ClaudeControlRequestEvent(
      requestId: "req-789",
      request: .canUseTool(
        toolName: "Edit",
        input: JSONValue([
          "file_path": "/Users/test/project/Sources/Main.swift",
          "old_string": "func hello()",
          "new_string": "func hello() async throws"
        ]),
        toolUseId: "tool-012"
      )
    ),
    onApprove: { print("Approved") },
    onDeny: { print("Denied") }
  )
}

#Preview("Write File") {
  ToolApprovalSheet(
    controlRequest: ClaudeControlRequestEvent(
      requestId: "req-abc",
      request: .canUseTool(
        toolName: "Write",
        input: JSONValue([
          "file_path": "/Users/test/project/README.md",
          "content": "# My Project\n\nThis is a sample project.\n\n## Installation\n\n```bash\nswift build\n```"
        ]),
        toolUseId: "tool-def"
      )
    ),
    onApprove: { print("Approved") },
    onDeny: { print("Denied") }
  )
}
