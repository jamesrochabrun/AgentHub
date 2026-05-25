//
//  RegularTerminalWorkspaceView.swift
//  AgentHub
//

import AppKit
import SwiftUI

typealias RegularTerminalPanelID = TerminalPanelKit.PanelID
typealias RegularTerminalTabID = TerminalPanelKit.TabID
typealias RegularTerminalSplitAxis = TerminalPanelKit.SplitAxis
typealias RegularTerminalPanelNavigationDirection = TerminalPanelKit.PanelNavigationDirection
typealias RegularTerminalTabNavigationDirection = TerminalPanelKit.TabNavigationDirection
typealias RegularTerminalSplitNode = TerminalPanelKit.SplitNode
typealias RegularTerminalShortcut = TerminalPanelKit.Shortcut
typealias RegularTerminalTab = TerminalPanelKit.Tab<SafeLocalProcessTerminalView>
typealias RegularTerminalPanel = TerminalPanelKit.Panel<SafeLocalProcessTerminalView>
typealias RegularTerminalSplitLayoutBuilder = TerminalPanelKit.SplitLayoutBuilder

enum RegularTerminalLaunchFeatures {
  // TODO: Re-enable regular terminal tabs after launch once SwiftTerm tab creation latency is solved.
  static let tabsEnabled = false
}

@MainActor
extension TerminalPanelKit.Tab where Payload == SafeLocalProcessTerminalView {
  var terminalView: SafeLocalProcessTerminalView {
    payload
  }

  convenience init(
    id: RegularTerminalTabID = RegularTerminalTabID(),
    role: TerminalWorkspaceTabRole,
    name: String? = nil,
    title: String? = nil,
    workingDirectory: String? = nil,
    linkedSession: TerminalWorkspaceLinkedSessionSnapshot? = nil,
    terminalView: SafeLocalProcessTerminalView
  ) {
    self.init(
      id: id,
      role: role,
      name: name,
      title: title,
      workingDirectory: workingDirectory,
      linkedSession: linkedSession,
      payload: terminalView
    )
  }
}

@MainActor
struct RegularTerminalWorkspaceView: View {
  let panels: [RegularTerminalPanel]
  let splitRoot: RegularTerminalSplitNode?
  let activePanelID: RegularTerminalPanelID?
  let maximizedPanelID: RegularTerminalPanelID?
  let canClosePanel: (RegularTerminalPanel) -> Bool
  let canCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Bool
  let onActivatePanel: (RegularTerminalPanel) -> Void
  let onSelectTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onClosePanel: (RegularTerminalPanel) -> Void
  let onCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onOpenTab: (RegularTerminalPanel) -> Void
  let onSplitPanel: (RegularTerminalPanel, RegularTerminalSplitAxis) -> Void
  let onToggleMaximizedPanel: (RegularTerminalPanel) -> Void

  var body: some View {
    if panels.isEmpty {
      Text("No terminal available")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      RegularTerminalSplitView(
        node: resolvedSplitRoot,
        panels: panels,
        activePanelID: activePanelID,
        maximizedPanelID: effectiveMaximizedPanelID,
        canClosePanel: canClosePanel,
        canCloseTab: canCloseTab,
        onActivatePanel: onActivatePanel,
        onSelectTab: onSelectTab,
        onClosePanel: onClosePanel,
        onCloseTab: onCloseTab,
        onOpenTab: onOpenTab,
        onSplitPanel: onSplitPanel,
        onToggleMaximizedPanel: onToggleMaximizedPanel
      )
    }
  }

  private var resolvedSplitRoot: RegularTerminalSplitNode {
    TerminalPanelKit.SplitPresentationResolver.resolvedRoot(
      splitRoot: splitRoot,
      panelIDs: panels.map(\.id),
      maximizedPanelID: maximizedPanelID
    ) ?? .panel(RegularTerminalPanelID())
  }

  private var effectiveMaximizedPanelID: RegularTerminalPanelID? {
    TerminalPanelKit.SplitPresentationResolver.validMaximizedPanelID(
      maximizedPanelID,
      panelIDs: panels.map(\.id)
    )
  }
}

@MainActor
private struct RegularTerminalSplitView: View {
  let node: RegularTerminalSplitNode
  let panels: [RegularTerminalPanel]
  let activePanelID: RegularTerminalPanelID?
  let maximizedPanelID: RegularTerminalPanelID?
  let canClosePanel: (RegularTerminalPanel) -> Bool
  let canCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Bool
  let onActivatePanel: (RegularTerminalPanel) -> Void
  let onSelectTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onClosePanel: (RegularTerminalPanel) -> Void
  let onCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onOpenTab: (RegularTerminalPanel) -> Void
  let onSplitPanel: (RegularTerminalPanel, RegularTerminalSplitAxis) -> Void
  let onToggleMaximizedPanel: (RegularTerminalPanel) -> Void

  var body: some View {
    content(for: node)
  }

  @ViewBuilder
  private func content(for node: RegularTerminalSplitNode) -> some View {
    switch node {
    case .panel(let panelID):
      if let panel = panels.first(where: { $0.id == panelID }) {
        RegularTerminalPaneView(
          panel: panel,
          isActive: panel.id == activePanelID,
          isMaximized: panel.id == maximizedPanelID,
          showsSelectionBorder: panels.count > 1 && maximizedPanelID == nil,
          canMaximize: panels.count > 1,
          canSplit: panels.count < 4,
          canClosePanel: canClosePanel(panel),
          canCloseTab: { tab in canCloseTab(panel, tab) },
          onActivatePanel: { onActivatePanel(panel) },
          onSelectTab: { tab in onSelectTab(panel, tab) },
          onClosePanel: { onClosePanel(panel) },
          onCloseTab: { tab in onCloseTab(panel, tab) },
          onOpenTab: { onOpenTab(panel) },
          onSplitRight: { onSplitPanel(panel, .horizontal) },
          onSplitBelow: { onSplitPanel(panel, .vertical) },
          onToggleMaximizedPanel: { onToggleMaximizedPanel(panel) }
        )
      } else {
        EmptyView()
      }

    case .split(let axis, let children):
      split(axis: axis, children: children)
    }
  }

  @ViewBuilder
  private func split(
    axis: RegularTerminalSplitAxis,
    children: [RegularTerminalSplitNode]
  ) -> some View {
    GeometryReader { proxy in
      switch axis {
      case .horizontal:
        horizontalSplit(children: children, size: proxy.size)
      case .vertical:
        verticalSplit(children: children, size: proxy.size)
      }
    }
  }

  private func horizontalSplit(
    children: [RegularTerminalSplitNode],
    size: CGSize
  ) -> some View {
    let dividerSize: CGFloat = 1
    let childCount = CGFloat(max(children.count, 1))
    let totalDividerWidth = dividerSize * CGFloat(max(children.count - 1, 0))
    let childWidth = max(0, size.width - totalDividerWidth) / childCount

    return HStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
        if offset > 0 {
          divider(axis: .horizontal)
        }
        RegularTerminalSplitView(
          node: child,
          panels: panels,
          activePanelID: activePanelID,
          maximizedPanelID: maximizedPanelID,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          onToggleMaximizedPanel: onToggleMaximizedPanel
        )
        .frame(width: childWidth, height: size.height)
      }
    }
  }

  private func verticalSplit(
    children: [RegularTerminalSplitNode],
    size: CGSize
  ) -> some View {
    let dividerSize: CGFloat = 1
    let childCount = CGFloat(max(children.count, 1))
    let totalDividerHeight = dividerSize * CGFloat(max(children.count - 1, 0))
    let childHeight = max(0, size.height - totalDividerHeight) / childCount

    return VStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
        if offset > 0 {
          divider(axis: .vertical)
        }
        RegularTerminalSplitView(
          node: child,
          panels: panels,
          activePanelID: activePanelID,
          maximizedPanelID: maximizedPanelID,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          onToggleMaximizedPanel: onToggleMaximizedPanel
        )
        .frame(width: size.width, height: childHeight)
      }
    }
  }

  @ViewBuilder
  private func divider(axis: RegularTerminalSplitAxis) -> some View {
    switch axis {
    case .horizontal:
      Color.primary.opacity(0.25)
        .frame(width: 1)
    case .vertical:
      Color.primary.opacity(0.25)
        .frame(height: 1)
    }
  }
}

@MainActor
private struct RegularTerminalPaneView: View {
  let panel: RegularTerminalPanel
  let isActive: Bool
  let isMaximized: Bool
  let showsSelectionBorder: Bool
  let canMaximize: Bool
  let canSplit: Bool
  let canClosePanel: Bool
  let canCloseTab: (RegularTerminalTab) -> Bool
  let onActivatePanel: () -> Void
  let onSelectTab: (RegularTerminalTab) -> Void
  let onClosePanel: () -> Void
  let onCloseTab: (RegularTerminalTab) -> Void
  let onOpenTab: () -> Void
  let onSplitRight: () -> Void
  let onSplitBelow: () -> Void
  let onToggleMaximizedPanel: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      RegularTerminalPaneHeader(
        panel: panel,
        isMaximized: isMaximized,
        canMaximize: canMaximize,
        canSplit: canSplit,
        canClosePanel: canClosePanel,
        canCloseTab: canCloseTab,
        onSelectTab: onSelectTab,
        onCloseTab: onCloseTab,
        onOpenTab: onOpenTab,
        onSplitRight: onSplitRight,
        onSplitBelow: onSplitBelow,
        onToggleMaximizedPanel: onToggleMaximizedPanel,
        onClosePanel: onClosePanel
      )

      if let activeTab = panel.activeTab {
        RegularTerminalTabRepresentable(tab: activeTab)
          .id(activeTab.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text("No tab available")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
    .contentShape(Rectangle())
    .onTapGesture(perform: onActivatePanel)
    .overlay {
      if isActive && showsSelectionBorder {
        Rectangle()
          .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
      }
    }
  }
}

@MainActor
private struct RegularTerminalPaneHeader: View {
  let panel: RegularTerminalPanel
  let isMaximized: Bool
  let canMaximize: Bool
  let canSplit: Bool
  let canClosePanel: Bool
  let canCloseTab: (RegularTerminalTab) -> Bool
  let onSelectTab: (RegularTerminalTab) -> Void
  let onCloseTab: (RegularTerminalTab) -> Void
  let onOpenTab: () -> Void
  let onSplitRight: () -> Void
  let onSplitBelow: () -> Void
  let onToggleMaximizedPanel: () -> Void
  let onClosePanel: () -> Void

  var body: some View {
    ZStack(alignment: .bottom) {
      Color(nsColor: .controlBackgroundColor)
        .opacity(0.85)

      Rectangle()
        .fill(Color.primary.opacity(0.16))
        .frame(height: 1)

      HStack(spacing: 0) {
        if RegularTerminalLaunchFeatures.tabsEnabled {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
              ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { index, tab in
                RegularTerminalTabItem(
                  title: tab.displayName(index: index),
                  isActive: tab.id == panel.activeTabID,
                  isFirst: index == 0,
                  canClose: canCloseTab(tab),
                  onSelect: { onSelectTab(tab) },
                  onClose: { onCloseTab(tab) }
                )
              }
            }
          }
        } else {
          Text(activeTabTitle)
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Spacer(minLength: 0)

        HStack(spacing: 2) {
          if RegularTerminalLaunchFeatures.tabsEnabled {
            RegularTerminalToolbarButton(
              title: "New Tab",
              systemImage: "plus",
              help: "New terminal tab",
              action: onOpenTab
            )
          }

          if canMaximize {
            RegularTerminalToolbarButton(
              title: isMaximized ? "Restore Pane" : "Maximize Pane",
              systemImage: isMaximized
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
              help: isMaximized
                ? "Restore terminal panes (Cmd+Shift+M)"
                : "Maximize terminal pane (Cmd+Shift+M)",
              action: onToggleMaximizedPanel
            )
          }

          RegularTerminalToolbarButton(
            title: "Split Right",
            systemImage: "rectangle.split.2x1",
            help: "Split terminal to the right",
            isDisabled: !canSplit,
            action: onSplitRight
          )

          RegularTerminalToolbarButton(
            title: "Split Below",
            systemImage: "rectangle.split.1x2",
            help: "Split terminal below",
            isDisabled: !canSplit,
            action: onSplitBelow
          )

          if canClosePanel {
            RegularTerminalToolbarButton(
              title: "Close Pane",
              systemImage: "xmark",
              help: "Close terminal pane",
              action: onClosePanel
            )
          }
        }
        .padding(.horizontal, 8)
      }
      .frame(height: 32)
    }
    .frame(height: 32)
  }

  private var activeTabTitle: String {
    panel.activeTab?.displayName(index: 0) ?? panel.name ?? "Terminal"
  }
}

@MainActor
private struct RegularTerminalTabItem: View {
  let title: String
  let isActive: Bool
  let isFirst: Bool
  let canClose: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovered = false
  @State private var isCloseHovered = false

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onSelect) {
        Text(title)
          .lineLimit(1)
          .truncationMode(.tail)
          .font(.system(size: 12, weight: isActive ? .semibold : .regular))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, isFirst ? 12 : 10)
          .padding(.trailing, canClose ? 6 : 10)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if canClose {
        Button("Close Tab", systemImage: "xmark", action: onClose)
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.secondary)
          .frame(width: 16, height: 16)
          .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(isCloseHovered ? Color.primary.opacity(0.10) : Color.clear)
          }
          .help("Close terminal tab")
          .padding(.trailing, 6)
          .onHover { hovering in
            isCloseHovered = hovering
          }
      }
    }
    .frame(height: 32)
    .frame(minWidth: 96, maxWidth: 180, alignment: .leading)
    .foregroundStyle(isActive ? Color.primary : Color.secondary)
    .background {
      Rectangle()
        .fill(backgroundColor)
    }
    .overlay(alignment: .bottom) {
      if isActive {
        Rectangle()
          .fill(Color.accentColor)
          .frame(height: 2)
      }
    }
    .contentShape(Rectangle())
    .help(title)
    .onHover { hovering in
      isHovered = hovering
    }
  }

  private var backgroundColor: Color {
    if isActive {
      return Color.primary.opacity(0.08)
    }
    if isHovered {
      return Color.primary.opacity(0.05)
    }
    return .clear
  }
}

@MainActor
private struct RegularTerminalToolbarButton: View {
  let title: String
  let systemImage: String
  let help: String
  let isDisabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  init(
    title: String,
    systemImage: String,
    help: String,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.help = help
    self.isDisabled = isDisabled
    self.action = action
  }

  var body: some View {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(isDisabled ? Color.secondary.opacity(0.45) : Color.secondary)
      .frame(width: 28, height: 28)
      .background {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(isHovered && !isDisabled ? Color.primary.opacity(0.08) : Color.clear)
      }
      .contentShape(Rectangle())
      .disabled(isDisabled)
      .accessibilityLabel(title)
      .help(help)
      .onHover { hovering in
        isHovered = hovering
      }
  }
}

@MainActor
private struct RegularTerminalTabRepresentable: NSViewRepresentable {
  let tab: RegularTerminalTab

  func makeNSView(context: Context) -> RegularTerminalTabHostView {
    let hostView = RegularTerminalTabHostView()
    hostView.mount(tab.terminalView, key: tab.id.rawValue.uuidString)
    return hostView
  }

  func updateNSView(_ nsView: RegularTerminalTabHostView, context: Context) {
    nsView.mount(tab.terminalView, key: tab.id.rawValue.uuidString)
  }
}

@MainActor
private final class RegularTerminalTabHostView: NSView {
  private var mountedKey: String?
  private weak var mountedView: NSView?

  func mount(_ terminalView: NSView, key: String) {
    guard mountedKey != key || mountedView !== terminalView else { return }

    mountedView?.removeFromSuperview()
    terminalView.removeFromSuperview()
    terminalView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(terminalView)
    NSLayoutConstraint.activate([
      terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
      terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
      terminalView.topAnchor.constraint(equalTo: topAnchor),
      terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    mountedKey = key
    mountedView = terminalView
  }
}
