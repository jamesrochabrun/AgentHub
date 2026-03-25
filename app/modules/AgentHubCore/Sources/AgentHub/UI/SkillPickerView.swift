//
//  SkillPickerView.swift
//  AgentHub
//
//  Slash-command picker overlay shown in the prompt editor when the user types "/".
//

import SwiftUI

// MARK: - SkillPickerView

struct SkillPickerView: View {

  let query: String
  let skills: [HubSkill]
  let selectedIndex: Int
  let onSelect: (HubSkill) -> Void
  let onDismiss: () -> Void

  private var filtered: [HubSkill] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return Array(skills.prefix(6)) }
    let lower = trimmed.lowercased()
    let matches = skills.filter {
      $0.name.lowercased().contains(lower) ||
      $0.description.lowercased().contains(lower)
    }
    return Array(matches.prefix(6))
  }

  var body: some View {
    if filtered.isEmpty { return AnyView(EmptyView()) }
    return AnyView(content)
  }

  private var content: some View {
    VStack(spacing: 0) {
      ForEach(Array(filtered.enumerated()), id: \.element.id) { index, skill in
        SkillPickerRow(
          skill: skill,
          isSelected: index == selectedIndex
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(skill) }

        if index < filtered.count - 1 {
          Divider()
            .opacity(0.5)
        }
      }
    }
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.12), radius: 8, y: -4)
  }
}

// MARK: - SkillPickerRow

private struct SkillPickerRow: View {
  let skill: HubSkill
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("/\(skill.name)")
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundColor(.primary)
          .lineLimit(1)
        if !skill.description.isEmpty {
          Text(skill.description)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      skillBadge
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.12)
        : Color.clear
    )
  }

  private var skillBadge: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(providerColor)
        .frame(width: 5, height: 5)
      Text("\(providerLabel) · \(skill.source.displayLabel)")
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      Capsule()
        .fill(Color.primary.opacity(0.06))
    )
  }

  private var providerLabel: String {
    switch skill.source.provider {
    case .claude: "Claude"
    case .codex:  "Codex"
    }
  }

  private var providerColor: Color {
    switch skill.source.provider {
    case .claude: Color.brandPrimary(for: SessionProviderKind.claude)
    case .codex:  Color.brandPrimary(for: SessionProviderKind.codex)
    }
  }
}
