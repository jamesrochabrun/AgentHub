//
//  ProjectDetailsSheetView.swift
//  AgentHub
//
//  Project Details panel: every session that belongs to a module (including
//  worktree sessions) plus the skills, rules, and MCP servers available to it,
//  with personal-vs-project scope and Claude/Codex availability called out.
//

import SwiftUI

// MARK: - ProjectDetailsSessionItem

struct ProjectDetailsSessionItem: Identifiable {
  let id: String
  let session: CLISession
  let providerKind: SessionProviderKind
  let timestamp: Date
  let isPending: Bool
  let status: SessionStatus?
  let customName: String?

  var displayName: String {
    customName ?? session.displayName
  }
}

// MARK: - ProjectDetailsTab

private enum ProjectDetailsTab: String, CaseIterable, Identifiable {
  case sessions = "Sessions"
  case skills = "Skills"
  case rules = "Rules"
  case mcps = "MCPs"

  var id: String { rawValue }
}

// MARK: - ProjectDetailsScopeFilter

private enum ProjectDetailsScopeFilter: Hashable {
  case all
  case scope(ProjectAssetScope)

  func allows(_ scope: ProjectAssetScope) -> Bool {
    switch self {
    case .all: return true
    case .scope(let filter): return filter == scope
    }
  }
}

// MARK: - ProjectDetailsSheetView

struct ProjectDetailsSheetView: View {
  let modulePath: String
  let displayName: String
  let claudeViewModel: CLISessionsViewModel
  let codexViewModel: CLISessionsViewModel
  let onDismiss: () -> Void
  let onSelectSession: (ProjectDetailsSessionItem) -> Void

  @State private var viewModel: ProjectDetailsViewModel
  @State private var selectedTab: ProjectDetailsTab = .sessions
  @State private var skillScopeFilter: ProjectDetailsScopeFilter = .all
  @State private var selectedSkill: ProjectAgentSkill?
  @State private var selectedRule: ProjectAgentRule?
  @Environment(\.colorScheme) private var colorScheme

  init(
    modulePath: String,
    displayName: String,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    inventoryService: any ProjectDetailsInventoryServiceProtocol = ProjectDetailsInventoryService.shared,
    onDismiss: @escaping () -> Void,
    onSelectSession: @escaping (ProjectDetailsSessionItem) -> Void
  ) {
    self.modulePath = modulePath
    self.displayName = displayName
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.onDismiss = onDismiss
    self.onSelectSession = onSelectSession
    let rootPath = WorktreeModuleResolver.bestMatch(
      for: modulePath,
      repositories: WorktreeModuleResolver.mergedRepositories(
        claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
      )
    )?.repository.path ?? WorktreeModuleResolver.normalizedDirectoryPath(modulePath)
    _viewModel = State(initialValue: ProjectDetailsViewModel(
      projectPath: rootPath,
      service: inventoryService
    ))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)

      ProjectDetailsTabBar(
        tabs: ProjectDetailsTab.allCases,
        count: tabCount,
        selection: $selectedTab
      )
      .padding(.horizontal, 20)

      Divider()

      tabContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .onChange(of: selectedTab) { _, _ in
      selectedSkill = nil
      selectedRule = nil
    }
    .background(Color.surfacePanel)
    .frame(
      minWidth: 960,
      idealWidth: 1240,
      maxWidth: .infinity,
      minHeight: 700,
      idealHeight: 920,
      maxHeight: .infinity
    )
    .onExitCommand { onDismiss() }
    .task { await viewModel.load() }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.primary)
        .frame(width: 36, height: 36)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.surfaceElevated)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .font(.geist(size: 16, weight: .bold))
          .foregroundStyle(.primary)
        Text((moduleRootPath as NSString).abbreviatingWithTildeInPath)
          .font(.primarySmall)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 8)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close")
    }
  }

  // MARK: Tab content

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .sessions:
      ProjectDetailsSessionsGrid(items: sessionItems, onSelect: onSelectSession)
    case .skills:
      if let selectedSkill {
        ProjectSkillDetailView(skill: selectedSkill) {
          self.selectedSkill = nil
        }
      } else {
        ProjectDetailsSkillsGrid(
          skills: viewModel.inventory.skills,
          isLoading: viewModel.isLoading,
          scopeFilter: $skillScopeFilter,
          onOpenSkill: { selectedSkill = $0 }
        )
      }
    case .rules:
      if let selectedRule {
        ProjectRuleDetailView(rule: selectedRule) {
          self.selectedRule = nil
        }
      } else {
        ProjectDetailsRulesList(
          rules: viewModel.inventory.rules,
          isLoading: viewModel.isLoading,
          onOpenRule: { selectedRule = $0 }
        )
      }
    case .mcps:
      ProjectDetailsMCPGrid(
        servers: viewModel.inventory.mcpServers,
        isLoading: viewModel.isLoading
      )
    }
  }

  private func tabCount(_ tab: ProjectDetailsTab) -> Int {
    switch tab {
    case .sessions: return sessionItems.count
    case .skills: return viewModel.inventory.skills.count
    case .rules: return viewModel.inventory.rules.count
    case .mcps: return viewModel.inventory.mcpServers.count
    }
  }

  // MARK: Session items

  private var mergedRepositories: [SelectedRepository] {
    WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    )
  }

  private var moduleRootPath: String {
    viewModel.projectPath
  }

  /// All sessions belonging to this module, worktree sessions included:
  /// resolving with `.parent` mode maps every worktree session back to the
  /// module root.
  private var sessionItems: [ProjectDetailsSessionItem] {
    let repositories = mergedRepositories
    let root = moduleRootPath

    func belongs(_ path: String) -> Bool {
      WorktreeModuleResolver.modulePath(for: path, repositories: repositories, mode: .parent) == root
    }

    var items: [ProjectDetailsSessionItem] = []
    for (providerViewModel, provider) in [(claudeViewModel, SessionProviderKind.claude),
                                          (codexViewModel, .codex)] {
      for pending in providerViewModel.pendingHubSessions
      where belongs(pending.placeholderSession.projectPath) {
        items.append(ProjectDetailsSessionItem(
          id: SidebarSessionItemID.pending(provider: provider, pendingId: pending.id),
          session: pending.placeholderSession,
          providerKind: provider,
          timestamp: pending.startedAt,
          isPending: true,
          status: nil,
          customName: nil
        ))
      }
      for session in providerViewModel.monitoredCLISessions where belongs(session.projectPath) {
        items.append(ProjectDetailsSessionItem(
          id: SidebarSessionItemID.monitored(provider: provider, sessionId: session.id),
          session: session,
          providerKind: provider,
          timestamp: session.lastActivityAt,
          isPending: false,
          status: providerViewModel.sessionStatus(for: session.id),
          customName: providerViewModel.sessionCustomNames[session.id]
        ))
      }
    }
    return items.sorted { $0.timestamp > $1.timestamp }
  }
}

// MARK: - ProjectDetailsTabBar

private struct ProjectDetailsTabBar: View {
  let tabs: [ProjectDetailsTab]
  let count: (ProjectDetailsTab) -> Int
  @Binding var selection: ProjectDetailsTab

  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 22) {
      ForEach(tabs) { tab in
        tabButton(for: tab)
      }
      Spacer(minLength: 0)
    }
  }

  private func tabButton(for tab: ProjectDetailsTab) -> some View {
    let isSelected = tab == selection
    return Button {
      selection = tab
    } label: {
      VStack(spacing: 6) {
        HStack(spacing: 5) {
          Text(tab.rawValue)
            .font(.geist(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
          Text("\(count(tab))")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        // The active theme's highlight (Ghostty-adopted themes included)
        // marks the selected tab.
        Rectangle()
          .fill(isSelected ? Color.brandPrimary(from: runtimeTheme) : Color.clear)
          .frame(height: 2)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Sessions grid

private struct ProjectDetailsSessionsGrid: View {
  let items: [ProjectDetailsSessionItem]
  let onSelect: (ProjectDetailsSessionItem) -> Void

  private let columns = [
    GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 12)
  ]

  var body: some View {
    if items.isEmpty {
      ProjectDetailsEmptyState(
        systemImage: "rectangle.stack",
        title: "No sessions",
        message: "Sessions launched in this module or its worktrees will show up here."
      )
    } else {
      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
          ForEach(items) { item in
            ProjectSessionGridCard(item: item) {
              onSelect(item)
            }
          }
        }
        .padding(20)
      }
    }
  }
}

// MARK: - ProjectSessionGridCard

/// Grid variant of the floating Sessions panel row: status dot, name,
/// provider tag, activity time, status line, and the session's paths.
private struct ProjectSessionGridCard: View {
  let item: ProjectDetailsSessionItem
  let onSelect: () -> Void

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 10) {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
          .shadow(color: statusColor.opacity(isWorking ? 0.55 : 0), radius: 4)
          .padding(.top, 5)

        VStack(alignment: .leading, spacing: 5) {
          topLine
          detailLine
          pathLines
        }

        Spacer(minLength: 8)

        Image(systemName: "arrow.up.forward")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary.opacity(isHovered ? 0.9 : 0.45))
          .padding(.top, 3)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
      .background(cardBackground)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
  }

  private var topLine: some View {
    HStack(spacing: 6) {
      Text(item.displayName)
        .font(.primaryDefault)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)

      Text(item.providerKind.rawValue)
        .font(.secondaryCaption)
        .foregroundStyle(Color.brandPrimary(from: runtimeTheme))
        .fixedSize(horizontal: true, vertical: false)

      Spacer(minLength: 4)

      Text(item.timestamp.timeAgoDisplay())
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var detailLine: some View {
    HStack(spacing: 6) {
      Text(statusText)
        .font(.secondarySmall)
        .foregroundStyle(statusColor)
        .lineLimit(1)

      Text("·")
        .font(.secondaryCaption)
        .foregroundStyle(.secondary.opacity(0.7))

      Text(projectText)
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var pathLines: some View {
    HStack(spacing: 5) {
      Image(systemName: item.session.isWorktree ? "arrow.triangle.branch" : "house")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary.opacity(0.7))
        .frame(width: 12, height: 12)

      Text((item.session.projectPath as NSString).abbreviatingWithTildeInPath)
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .help(item.session.projectPath)
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(isHovered
            ? Color.brandPrimary(from: runtimeTheme).opacity(colorScheme == .dark ? 0.16 : 0.22)
            : Color.surfaceOverlay.opacity(colorScheme == .dark ? 0.55 : 0.65))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(isHovered ? 0.24 : 0.12), lineWidth: 1)
      )
  }

  private var projectText: String {
    if let branchName = item.session.branchName, !branchName.isEmpty {
      return "\(item.session.projectName) · \(branchName)"
    }
    return item.session.projectName
  }

  private var isWorking: Bool {
    if case .thinking = item.status { return true }
    if case .executingTool = item.status { return true }
    return false
  }

  private var statusText: String {
    if item.isPending { return "starting" }
    guard let status = item.status else { return item.session.isActive ? "active" : "idle" }
    switch status {
    case .thinking:
      return "working"
    case .executingTool(let name):
      return name.lowercased()
    case .waitingForUser:
      return "ready"
    case .awaitingApproval(let tool):
      return "approval: \(tool.lowercased())"
    case .idle:
      return "idle"
    }
  }

  private var statusColor: Color {
    if item.isPending { return .orange }
    guard let status = item.status else { return .secondary }
    switch status {
    case .thinking, .executingTool:
      return .blue
    case .waitingForUser:
      return .green
    case .awaitingApproval:
      return .yellow
    case .idle:
      return .secondary
    }
  }
}

// MARK: - Skills grid

private struct ProjectDetailsSkillsGrid: View {
  let skills: [ProjectAgentSkill]
  let isLoading: Bool
  @Binding var scopeFilter: ProjectDetailsScopeFilter
  let onOpenSkill: (ProjectAgentSkill) -> Void

  private let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12)
  ]

  var body: some View {
    if isLoading, skills.isEmpty {
      ProjectDetailsLoadingState()
    } else if skills.isEmpty {
      ProjectDetailsEmptyState(
        systemImage: "sparkles",
        title: "No skills found",
        message: "Skills installed in ~/.claude/skills, ~/.codex/skills, or this project's .claude/skills will show up here."
      )
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ProjectDetailsScopeFilterChips(
          filter: $scopeFilter,
          totalCount: skills.count,
          personalCount: skills.filter { $0.scope == .personal }.count,
          projectCount: skills.filter { $0.scope == .project }.count
        )
        .padding(.horizontal, 20)
        .padding(.top, 14)

        ScrollView {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(filteredSkills) { skill in
              ProjectSkillCard(skill: skill) {
                onOpenSkill(skill)
              }
            }
          }
          .padding(20)
        }
      }
    }
  }

  private var filteredSkills: [ProjectAgentSkill] {
    skills.filter { scopeFilter.allows($0.scope) }
  }
}

// MARK: - ProjectDetailsScopeFilterChips

private struct ProjectDetailsScopeFilterChips: View {
  @Binding var filter: ProjectDetailsScopeFilter
  let totalCount: Int
  let personalCount: Int
  let projectCount: Int

  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack(spacing: 8) {
      chip("All", count: totalCount, value: .all)
      chip("Personal", count: personalCount, value: .scope(.personal))
      chip("Project", count: projectCount, value: .scope(.project))
      Spacer(minLength: 0)
    }
  }

  private func chip(_ title: String, count: Int, value: ProjectDetailsScopeFilter) -> some View {
    let isSelected = filter == value
    return Button {
      filter = value
    } label: {
      HStack(spacing: 4) {
        Text(title)
          .font(.geist(size: 11, weight: isSelected ? .semibold : .medium))
        Text("\(count)")
          .font(.secondaryCaption)
          .monospacedDigit()
          .opacity(0.7)
      }
      .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        Capsule().fill(isSelected ? Color.surfaceElevated : Color.clear)
      )
      .overlay(
        Capsule().stroke(
          isSelected
            ? Color.brandPrimary(from: runtimeTheme).opacity(0.55)
            : Color.secondary.opacity(0.15),
          lineWidth: 1
        )
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - ProjectSkillCard

private struct ProjectSkillCard: View {
  let skill: ProjectAgentSkill
  let onTap: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 10) {
        ProjectAssetCardIcon(systemImage: "sparkles")

        VStack(alignment: .leading, spacing: 6) {
          Text(skill.name)
            .font(.primaryDefault)
            .foregroundStyle(.primary)
            .lineLimit(1)

          if !skill.skillDescription.isEmpty {
            Text(skill.skillDescription)
              .font(.secondarySmall)
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
          }

          HStack(spacing: 6) {
            ProjectAssetScopeBadge(scope: skill.scope)
            ProjectAssetProviderBadges(providers: skill.providers)
            if skill.supportingFileCount > 0 {
              ProjectAssetBadge(
                text: "\(skill.supportingFileCount) file\(skill.supportingFileCount == 1 ? "" : "s")"
              )
            }
          }
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary.opacity(isHovered ? 0.9 : 0.4))
          .padding(.top, 4)
      }
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .projectDetailsCardBackground(highlighted: isHovered)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
  }
}

// MARK: - Rules list

private struct ProjectDetailsRulesList: View {
  let rules: [ProjectAgentRule]
  let isLoading: Bool
  let onOpenRule: (ProjectAgentRule) -> Void

  private let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12)
  ]

  var body: some View {
    if isLoading, rules.isEmpty {
      ProjectDetailsLoadingState()
    } else if rules.isEmpty {
      ProjectDetailsEmptyState(
        systemImage: "list.bullet.rectangle",
        title: "No rules found",
        message: "CLAUDE.md, AGENTS.md, and Codex rules files for this project will show up here."
      )
    } else {
      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
          ForEach(rules) { rule in
            ProjectRuleCard(rule: rule) {
              onOpenRule(rule)
            }
          }
        }
        .padding(20)
      }
    }
  }
}

// MARK: - ProjectRuleCard

private struct ProjectRuleCard: View {
  let rule: ProjectAgentRule
  let onTap: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 10) {
        ProjectAssetCardIcon(systemImage: "list.bullet.rectangle")

        VStack(alignment: .leading, spacing: 6) {
          Text(rule.title)
            .font(.primaryDefault)
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text((rule.path as NSString).abbreviatingWithTildeInPath)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

          if !rule.preview.isEmpty {
            Text(rule.preview)
              .font(.secondarySmall)
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
          }

          HStack(spacing: 6) {
            ProjectAssetScopeBadge(scope: rule.scope)
            ProjectAssetProviderBadges(providers: rule.providers)
            ProjectAssetBadge(text: "\(rule.lineCount) lines")
          }
        }

        Spacer(minLength: 0)

        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary.opacity(isHovered ? 0.9 : 0.4))
          .padding(.top, 4)
      }
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .projectDetailsCardBackground(highlighted: isHovered)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
  }
}

// MARK: - MCP grid

private struct ProjectDetailsMCPGrid: View {
  let servers: [ProjectMCPServerEntry]
  let isLoading: Bool

  private let columns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12)
  ]

  var body: some View {
    if isLoading, servers.isEmpty {
      ProjectDetailsLoadingState()
    } else if servers.isEmpty {
      ProjectDetailsEmptyState(
        systemImage: "server.rack",
        title: "No MCP servers found",
        message: "MCP servers configured in ~/.claude.json, this project's .mcp.json, or ~/.codex/config.toml will show up here."
      )
    } else {
      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
          ForEach(servers) { server in
            ProjectMCPCard(server: server)
          }
        }
        .padding(20)
      }
    }
  }
}

// MARK: - ProjectMCPCard

private struct ProjectMCPCard: View {
  let server: ProjectMCPServerEntry

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ProjectAssetCardIcon(systemImage: "server.rack")

      VStack(alignment: .leading, spacing: 6) {
        Text(server.name)
          .font(.primaryDefault)
          .foregroundStyle(.primary)
          .lineLimit(1)

        if !server.detail.isEmpty {
          Text(server.detail)
            .font(.primaryCaption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
        }

        HStack(spacing: 6) {
          ProjectAssetScopeBadge(scope: server.scope)
          ProjectAssetProviderBadges(providers: server.providers)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .projectDetailsCardBackground()
  }
}

// MARK: - Badges

struct ProjectAssetScopeBadge: View {
  let scope: ProjectAssetScope

  var body: some View {
    ProjectAssetBadge(text: scope == .personal ? "Personal" : "Project")
  }
}

struct ProjectAssetProviderBadges: View {
  let providers: Set<SessionProviderKind>

  var body: some View {
    ForEach(SessionProviderKind.allCases.filter(providers.contains), id: \.self) { provider in
      ProjectAssetBadge(text: provider.rawValue)
    }
  }
}

/// Neutral pill badge — theme accents are reserved for selection and the tab
/// underline, so metadata stays quiet.
struct ProjectAssetBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.geist(size: 10, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.surfaceElevated)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
      )
      .fixedSize()
  }
}

/// Neutral rounded-square icon used by every asset card.
struct ProjectAssetCardIcon: View {
  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.surfaceElevated)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
      )
  }
}

// MARK: - Empty & loading states

private struct ProjectDetailsEmptyState: View {
  let systemImage: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(.secondary.opacity(0.6))
      Text(title)
        .font(.secondaryDefault)
        .foregroundStyle(.primary)
      Text(message)
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ProjectDetailsLoadingState: View {
  var body: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("Scanning configuration…")
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Card background

private struct ProjectDetailsCardBackground: ViewModifier {
  var highlighted = false

  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(highlighted
                ? Color.surfaceHover.opacity(colorScheme == .dark ? 0.8 : 0.9)
                : Color.surfaceOverlay.opacity(colorScheme == .dark ? 0.55 : 0.65))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.secondary.opacity(highlighted ? 0.24 : 0.12), lineWidth: 1)
          )
      )
  }
}

private extension View {
  func projectDetailsCardBackground(highlighted: Bool = false) -> some View {
    modifier(ProjectDetailsCardBackground(highlighted: highlighted))
  }
}
