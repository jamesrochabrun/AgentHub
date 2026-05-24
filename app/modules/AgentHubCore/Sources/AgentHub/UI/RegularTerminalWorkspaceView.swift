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
  @State private var panelFrames: [RegularTerminalPanelID: CGRect] = [:]
  @State private var dragState: RegularTerminalPanelDragState?

  let panels: [RegularTerminalPanel]
  let splitRoot: RegularTerminalSplitNode?
  let activePanelID: RegularTerminalPanelID?
  let canClosePanel: (RegularTerminalPanel) -> Bool
  let canCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Bool
  let onActivatePanel: (RegularTerminalPanel) -> Void
  let onSelectTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onClosePanel: (RegularTerminalPanel) -> Void
  let onCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onOpenTab: (RegularTerminalPanel) -> Void
  let onSplitPanel: (RegularTerminalPanel, RegularTerminalSplitAxis) -> Void
  let onRearrangePanels: (RegularTerminalSplitNode) -> Void

  var body: some View {
    GeometryReader { proxy in
      if panels.isEmpty {
        Text("No terminal available")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        RegularTerminalSplitView(
          node: displayedSplitRoot,
          panels: panels,
          activePanelID: activePanelID,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          dragVisualState: dragVisualState(for:),
          coordinateSpaceName: Self.coordinateSpaceName,
          onPanelDragChanged: { panel, value in
            updatePanelDrag(panel, value: value, containerSize: proxy.size)
          },
          onPanelDragEnded: { _, _ in
            finishPanelDrag()
          }
        )
      }
    }
    .coordinateSpace(name: Self.coordinateSpaceName)
    .onPreferenceChange(RegularTerminalPanelFramePreferenceKey.self) { frames in
      panelFrames = frames
    }
    .onChange(of: panelIdentity) { _, _ in
      dragState = nil
    }
  }

  private var resolvedSplitRoot: RegularTerminalSplitNode {
    splitRoot ?? panels.first.map { .panel($0.id) } ?? .panel(RegularTerminalPanelID())
  }

  private var displayedSplitRoot: RegularTerminalSplitNode {
    dragState?.proposalRoot ?? resolvedSplitRoot
  }

  private var panelIdentity: [RegularTerminalPanelID] {
    panels.map(\.id)
  }

  private static let coordinateSpaceName = "RegularTerminalWorkspaceCoordinateSpace"
  private static let nearestTargetDistance: CGFloat = 96

  private func updatePanelDrag(
    _ panel: RegularTerminalPanel,
    value: DragGesture.Value,
    containerSize: CGSize
  ) {
    guard panels.count > 1 else { return }
    let sourceRoot = dragState?.sourceRoot ?? resolvedSplitRoot
    let sourceFrames = dragState?.sourceFrames ?? usablePanelFrames(
      containerSize: containerSize,
      root: sourceRoot
    )

    guard let target = targetPanel(at: value.location, dragging: panel.id, frames: sourceFrames) else {
      dragState = RegularTerminalPanelDragState(
        draggedPanelID: panel.id,
        sourceRoot: sourceRoot,
        sourceFrames: sourceFrames,
        proposalRoot: nil,
        isInvalid: true
      )
      return
    }

    let placement = dropPlacement(for: value.location, in: target.frame)
    let proposal = TerminalPanelDragLayoutEngine.proposal(
      root: sourceRoot.terminalPanelLayoutNode,
      dragging: panel.id,
      over: target.id,
      placement: placement,
      containerSize: containerSize
    )

    dragState = RegularTerminalPanelDragState(
      draggedPanelID: panel.id,
      sourceRoot: sourceRoot,
      sourceFrames: sourceFrames,
      proposalRoot: proposal.map { RegularTerminalSplitNode(layoutNode: $0.root) },
      isInvalid: proposal == nil
    )
  }

  private func finishPanelDrag() {
    defer { dragState = nil }
    guard let proposalRoot = dragState?.proposalRoot,
          dragState?.isInvalid == false else {
      return
    }
    onRearrangePanels(proposalRoot)
  }

  private func dragVisualState(for panelID: RegularTerminalPanelID) -> TerminalPanelDragVisualState {
    guard dragState?.draggedPanelID == panelID else { return .inactive }
    return dragState?.isInvalid == true ? .invalid : .preview
  }

  private func targetPanel(
    at point: CGPoint,
    dragging draggedPanelID: RegularTerminalPanelID,
    frames sourceFrames: [RegularTerminalPanelID: CGRect]
  ) -> (id: RegularTerminalPanelID, frame: CGRect)? {
    let frames = sourceFrames.filter { $0.key != draggedPanelID }
    guard !frames.isEmpty else { return nil }

    if let contained = frames.first(where: { $0.value.insetBy(dx: -12, dy: -12).contains(point) }) {
      return (contained.key, contained.value)
    }

    guard let nearest = frames.min(by: {
      distance(from: point, to: $0.value) < distance(from: point, to: $1.value)
    }) else {
      return nil
    }
    guard distance(from: point, to: nearest.value) <= Self.nearestTargetDistance else {
      return nil
    }
    return (nearest.key, nearest.value)
  }

  private func usablePanelFrames(
    containerSize: CGSize,
    root: RegularTerminalSplitNode
  ) -> [RegularTerminalPanelID: CGRect] {
    if !panelFrames.isEmpty {
      return panelFrames
    }
    return TerminalPanelDragLayoutEngine.panelFrames(
      for: root.terminalPanelLayoutNode,
      in: CGRect(origin: .zero, size: containerSize)
    )
  }

  private func dropPlacement(for point: CGPoint, in frame: CGRect) -> TerminalPanelDropPlacement {
    let distances: [(distance: CGFloat, placement: TerminalPanelDropPlacement)] = [
      (abs(point.x - frame.minX), .leading),
      (abs(point.x - frame.maxX), .trailing),
      (abs(point.y - frame.minY), .above),
      (abs(point.y - frame.maxY), .below)
    ]
    return distances.min(by: { $0.distance < $1.distance })?.placement ?? .trailing
  }

  private func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
    let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
    let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
    return sqrt(dx * dx + dy * dy)
  }
}

private struct RegularTerminalPanelDragState {
  let draggedPanelID: RegularTerminalPanelID
  let sourceRoot: RegularTerminalSplitNode
  let sourceFrames: [RegularTerminalPanelID: CGRect]
  let proposalRoot: RegularTerminalSplitNode?
  let isInvalid: Bool
}

@MainActor
private struct RegularTerminalSplitView: View {
  let node: RegularTerminalSplitNode
  let panels: [RegularTerminalPanel]
  let activePanelID: RegularTerminalPanelID?
  let canClosePanel: (RegularTerminalPanel) -> Bool
  let canCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Bool
  let onActivatePanel: (RegularTerminalPanel) -> Void
  let onSelectTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onClosePanel: (RegularTerminalPanel) -> Void
  let onCloseTab: (RegularTerminalPanel, RegularTerminalTab) -> Void
  let onOpenTab: (RegularTerminalPanel) -> Void
  let onSplitPanel: (RegularTerminalPanel, RegularTerminalSplitAxis) -> Void
  let dragVisualState: (RegularTerminalPanelID) -> TerminalPanelDragVisualState
  let coordinateSpaceName: String
  let onPanelDragChanged: (RegularTerminalPanel, DragGesture.Value) -> Void
  let onPanelDragEnded: (RegularTerminalPanel, DragGesture.Value) -> Void

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
          showsSelectionBorder: panels.count > 1,
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
          dragVisualState: dragVisualState(panel.id),
          coordinateSpaceName: coordinateSpaceName,
          onDragChanged: { value in onPanelDragChanged(panel, value) },
          onDragEnded: { value in onPanelDragEnded(panel, value) }
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
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          dragVisualState: dragVisualState,
          coordinateSpaceName: coordinateSpaceName,
          onPanelDragChanged: onPanelDragChanged,
          onPanelDragEnded: onPanelDragEnded
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
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          dragVisualState: dragVisualState,
          coordinateSpaceName: coordinateSpaceName,
          onPanelDragChanged: onPanelDragChanged,
          onPanelDragEnded: onPanelDragEnded
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
  let showsSelectionBorder: Bool
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
  let dragVisualState: TerminalPanelDragVisualState
  let coordinateSpaceName: String
  let onDragChanged: (DragGesture.Value) -> Void
  let onDragEnded: (DragGesture.Value) -> Void

  var body: some View {
    VStack(spacing: 0) {
      RegularTerminalPaneHeader(
        panel: panel,
        canSplit: canSplit,
        canClosePanel: canClosePanel,
        canCloseTab: canCloseTab,
        onSelectTab: onSelectTab,
        onCloseTab: onCloseTab,
        onOpenTab: onOpenTab,
        onSplitRight: onSplitRight,
        onSplitBelow: onSplitBelow,
        onClosePanel: onClosePanel
      )
      .simultaneousGesture(panelDragGesture)

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
    .background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: RegularTerminalPanelFramePreferenceKey.self,
          value: [panel.id: proxy.frame(in: .named(coordinateSpaceName))]
        )
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onActivatePanel)
    .overlay {
      if dragVisualState == .invalid {
        Rectangle()
          .stroke(Color.red.opacity(0.85), lineWidth: 2)
      } else if dragVisualState == .preview {
        Rectangle()
          .stroke(Color.accentColor.opacity(0.75), lineWidth: 1)
      } else if isActive && showsSelectionBorder {
        Rectangle()
          .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
      }
    }
  }

  private var panelDragGesture: some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .named(coordinateSpaceName))
      .onChanged(onDragChanged)
      .onEnded(onDragEnded)
  }
}

private struct RegularTerminalPanelFramePreferenceKey: PreferenceKey {
  static var defaultValue: [RegularTerminalPanelID: CGRect] = [:]

  static func reduce(
    value: inout [RegularTerminalPanelID: CGRect],
    nextValue: () -> [RegularTerminalPanelID: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

@MainActor
private struct RegularTerminalPaneHeader: View {
  let panel: RegularTerminalPanel
  let canSplit: Bool
  let canClosePanel: Bool
  let canCloseTab: (RegularTerminalTab) -> Bool
  let onSelectTab: (RegularTerminalTab) -> Void
  let onCloseTab: (RegularTerminalTab) -> Void
  let onOpenTab: () -> Void
  let onSplitRight: () -> Void
  let onSplitBelow: () -> Void
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
