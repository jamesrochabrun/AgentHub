//
//  TerminalPanelKit.swift
//  AgentHub
//

import AppKit
import Foundation

public enum TerminalPanelKit {
  public struct PanelID: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID

    public var rawValue: UUID {
      id
    }

    public init(_ id: UUID = UUID()) {
      self.id = id
    }
  }

  public struct TabID: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID

    public var rawValue: UUID {
      id
    }

    public init(_ id: UUID = UUID()) {
      self.id = id
    }
  }

  public enum SplitAxis: Codable, Equatable, Sendable {
    case horizontal
    case vertical
  }

  public enum PanelNavigationDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
  }

  public enum TabNavigationDirection: Equatable, Sendable {
    case previous
    case next
  }

  public indirect enum SplitNode: Codable, Equatable, Sendable {
    case panel(PanelID)
    case split(axis: SplitAxis, children: [SplitNode])

    public var panelIDs: [PanelID] {
      switch self {
      case .panel(let panelID):
        return [panelID]
      case .split(_, let children):
        return children.flatMap(\.panelIDs)
      }
    }

    public func containsPanel(_ panelID: PanelID) -> Bool {
      switch self {
      case .panel(let currentPanelID):
        return currentPanelID == panelID
      case .split(_, let children):
        return children.contains { $0.containsPanel(panelID) }
      }
    }
  }

  public enum Shortcut: Equatable {
    case startSearch
    case openTab
    case openPane(axis: SplitAxis)
    case closePanel
    case focusPanel(PanelNavigationDirection)
    case selectTab(TabNavigationDirection)

    public static func action(
      for event: NSEvent,
      terminalTextInputActive: Bool = false
    ) -> Shortcut? {
      action(
        keyCode: event.keyCode,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        modifierFlags: event.modifierFlags,
        terminalTextInputActive: terminalTextInputActive
      )
    }

    public static func action(
      keyCode: UInt16,
      charactersIgnoringModifiers: String?,
      modifierFlags: NSEvent.ModifierFlags,
      terminalTextInputActive: Bool = false
    ) -> Shortcut? {
      let flags = normalizedModifierFlags(modifierFlags)
      let key = charactersIgnoringModifiers?.lowercased()

      if terminalTextInputActive && isTerminalEditingShortcut(keyCode: keyCode, flags: flags) {
        return nil
      }

      if flags == [.command] {
        switch keyCode {
        case 123: return .focusPanel(.left)
        case 124: return .focusPanel(.right)
        case 125: return .focusPanel(.down)
        case 126: return .focusPanel(.up)
        default:
          break
        }

        switch key {
        case "f": return .startSearch
        case "t": return .openTab
        case "d": return .openPane(axis: .horizontal)
        default: return nil
        }
      }

      if flags == [.command, .shift] {
        switch keyCode {
        case 123: return .selectTab(.previous)
        case 124: return .selectTab(.next)
        default:
          break
        }

        switch key {
        case "d": return .openPane(axis: .vertical)
        case "w": return .closePanel
        default: return nil
        }
      }

      return nil
    }

    private static func normalizedModifierFlags(
      _ flags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
      flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    }

    private static func isTerminalEditingShortcut(
      keyCode: UInt16,
      flags: NSEvent.ModifierFlags
    ) -> Bool {
      guard !flags.contains(.control),
            flags.contains(.command) || flags.contains(.option) else {
        return false
      }

      switch keyCode {
      case 51, 117, 123, 124, 125, 126:
        return true
      default:
        return false
      }
    }
  }

  public enum PaneActivity: Equatable {
    case starting
    case closingPanel
    case closingTerminal

    public var message: String {
      switch self {
      case .starting:
        return "Starting terminal..."
      case .closingPanel:
        return "Closing panel..."
      case .closingTerminal:
        return "Closing terminal..."
      }
    }
  }

  public struct ClosedTab<Payload> {
    public let panelID: PanelID
    public let tabID: TabID
    public let payload: Payload
  }

  public struct CloseResult<Payload> {
    public let closedPanelID: PanelID?
    public let closedTabs: [ClosedTab<Payload>]

    public static var empty: CloseResult<Payload> {
      CloseResult(closedPanelID: nil, closedTabs: [])
    }

    public var payloads: [Payload] {
      closedTabs.map(\.payload)
    }
  }

  @MainActor
  public final class Tab<Payload>: Identifiable {
    public let id: TabID
    public var role: TerminalWorkspaceTabRole
    public var name: String?
    public var title: String?
    public var workingDirectory: String?
    public var linkedSession: TerminalWorkspaceLinkedSessionSnapshot?
    public let payload: Payload

    public init(
      id: TabID = TabID(),
      role: TerminalWorkspaceTabRole,
      name: String? = nil,
      title: String? = nil,
      workingDirectory: String? = nil,
      linkedSession: TerminalWorkspaceLinkedSessionSnapshot? = nil,
      payload: Payload
    ) {
      self.id = id
      self.role = role
      self.name = name
      self.title = title
      self.workingDirectory = workingDirectory
      self.linkedSession = linkedSession
      self.payload = payload
    }

    public func displayName(index: Int) -> String {
      if let name = Self.nonEmpty(name) {
        return name
      }
      if let title = Self.nonEmpty(title) {
        return title
      }
      if let workingDirectory = Self.nonEmpty(workingDirectory),
         let directoryName = Self.directoryDisplayName(from: workingDirectory) {
        return directoryName
      }
      switch role {
      case .agent:
        return "Agent"
      case .shell:
        return index == 0 ? "Shell" : "Shell \(index + 1)"
      }
    }

    private static func nonEmpty(_ value: String?) -> String? {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func directoryDisplayName(from workingDirectory: String) -> String? {
      let lastPathComponent = URL(fileURLWithPath: workingDirectory).lastPathComponent
      guard !lastPathComponent.isEmpty, lastPathComponent != "/" else {
        return workingDirectory
      }
      return lastPathComponent
    }
  }

  @MainActor
  public final class Panel<Payload>: Identifiable {
    public let id: PanelID
    public let role: TerminalWorkspacePanelRole
    public var name: String?
    public private(set) var tabs: [Tab<Payload>]
    public private(set) var activeTabID: TabID

    public init(
      id: PanelID = PanelID(),
      role: TerminalWorkspacePanelRole,
      name: String? = nil,
      tabs: [Tab<Payload>],
      activeTabID: TabID? = nil
    ) {
      self.id = id
      self.role = role
      self.name = name
      self.tabs = tabs
      self.activeTabID = activeTabID ?? tabs.first?.id ?? TabID()
    }

    public var activeTab: Tab<Payload>? {
      tab(for: activeTabID) ?? tabs.first
    }

    public func tab(for id: TabID) -> Tab<Payload>? {
      tabs.first { $0.id == id }
    }

    public func appendTab(_ tab: Tab<Payload>) {
      tabs.append(tab)
      activeTabID = tab.id
    }

    @discardableResult
    public func selectTab(_ id: TabID) -> Bool {
      guard tab(for: id) != nil else { return false }
      activeTabID = id
      return true
    }

    @discardableResult
    public func removeTab(_ id: TabID) -> ClosedTab<Payload>? {
      let tabIDs = tabs.map(\.id)
      guard tabIDs.contains(id),
            let nextActiveTabID = Self.activeTabIDAfterClosing(
              id,
              tabIDs: tabIDs,
              activeTabID: activeTabID
            ),
            let index = tabs.firstIndex(where: { $0.id == id }) else {
        return nil
      }

      let tab = tabs.remove(at: index)
      activeTabID = nextActiveTabID
      return ClosedTab(panelID: self.id, tabID: tab.id, payload: tab.payload)
    }

    @discardableResult
    public func keepOnlyTab(_ id: TabID) -> [ClosedTab<Payload>] {
      guard tab(for: id) != nil else { return [] }
      let closedTabs = tabs
        .filter { $0.id != id }
        .map { ClosedTab(panelID: self.id, tabID: $0.id, payload: $0.payload) }
      tabs.removeAll { $0.id != id }
      activeTabID = id
      return closedTabs
    }

    nonisolated public static func activeTabIDAfterClosing(
      _ closingID: TabID,
      tabIDs: [TabID],
      activeTabID: TabID
    ) -> TabID? {
      guard let closingIndex = tabIDs.firstIndex(of: closingID) else {
        return activeTabID
      }

      var remainingIDs = tabIDs
      remainingIDs.remove(at: closingIndex)

      guard activeTabID == closingID else {
        return remainingIDs.contains(activeTabID) ? activeTabID : remainingIDs.first
      }

      if closingIndex < remainingIDs.count {
        return remainingIDs[closingIndex]
      }

      return remainingIDs.last
    }
  }

  @MainActor
  public final class Session<Payload> {
    public private(set) var panels: [Panel<Payload>]
    public private(set) var primaryPanelID: PanelID
    public private(set) var activePanelID: PanelID
    public private(set) var splitRoot: SplitNode?

    public init(primaryPanel: Panel<Payload>) {
      self.panels = [primaryPanel]
      self.primaryPanelID = primaryPanel.id
      self.activePanelID = primaryPanel.id
      self.splitRoot = .panel(primaryPanel.id)
    }

    public convenience init(
      primaryTab: Tab<Payload>,
      primaryName: String? = nil
    ) {
      self.init(primaryPanel: Panel(
        role: .primary,
        name: primaryName,
        tabs: [primaryTab],
        activeTabID: primaryTab.id
      ))
    }

    public var primaryPanel: Panel<Payload>? {
      panel(for: primaryPanelID)
    }

    public var activePanel: Panel<Payload>? {
      panel(for: activePanelID) ?? primaryPanel ?? panels.first
    }

    public var activeTab: Tab<Payload>? {
      activePanel?.activeTab
    }

    public var allTabs: [Tab<Payload>] {
      panels.flatMap(\.tabs)
    }

    public var canOpenPanel: Bool {
      panels.count < 4
    }

    public func panel(for id: PanelID?) -> Panel<Payload>? {
      guard let id else { return nil }
      return panels.first { $0.id == id }
    }

    public func tab(
      for tabID: TabID,
      in panelID: PanelID
    ) -> Tab<Payload>? {
      panel(for: panelID)?.tab(for: tabID)
    }

    @discardableResult
    public func appendTab(
      _ tab: Tab<Payload>,
      in panelID: PanelID? = nil
    ) -> Bool {
      guard let panel = panel(for: panelID ?? activePanelID) else { return false }
      panel.appendTab(tab)
      activePanelID = panel.id
      return true
    }

    @discardableResult
    public func openPanel(
      with tab: Tab<Payload>,
      beside anchorPanelID: PanelID,
      axis: SplitAxis,
      name: String? = nil
    ) -> Panel<Payload>? {
      guard canOpenPanel, panel(for: anchorPanelID) != nil else { return nil }
      let panel = Panel(
        role: .auxiliary,
        name: name,
        tabs: [tab],
        activeTabID: tab.id
      )
      panels.append(panel)
      activePanelID = panel.id
      splitRoot = SplitLayoutBuilder.addingPanel(
        panel.id,
        to: currentSplitRoot(),
        beside: anchorPanelID,
        axis: axis
      )
      return panel
    }

    public func canClosePanel(_ panelID: PanelID) -> Bool {
      panelID != primaryPanelID && panels.count > 1
    }

    public func canCloseTab(
      _ tabID: TabID,
      in panelID: PanelID,
      isProtected: Bool = false
    ) -> Bool {
      guard !isProtected, let panel = panel(for: panelID), panel.tab(for: tabID) != nil else {
        return false
      }
      return panel.tabs.count > 1 || canClosePanel(panel.id)
    }

    @discardableResult
    public func closePanel(_ panelID: PanelID) -> CloseResult<Payload> {
      guard canClosePanel(panelID),
            let panelIndex = panels.firstIndex(where: { $0.id == panelID }) else {
        return .empty
      }

      let panel = panels.remove(at: panelIndex)
      let closedTabs = panel.tabs.map {
        ClosedTab(panelID: panel.id, tabID: $0.id, payload: $0.payload)
      }
      splitRoot = SplitLayoutBuilder.removingPanel(panel.id, from: currentSplitRoot())

      if activePanelID == panelID {
        activePanelID = primaryPanelID
      }

      return CloseResult(closedPanelID: panel.id, closedTabs: closedTabs)
    }

    @discardableResult
    public func closeTab(_ tabID: TabID, in panelID: PanelID) -> CloseResult<Payload> {
      guard let panel = panel(for: panelID), panel.tab(for: tabID) != nil else {
        return .empty
      }

      if panel.tabs.count == 1 {
        return closePanel(panelID)
      }

      guard let closedTab = panel.removeTab(tabID) else {
        return .empty
      }
      activePanelID = panel.id
      return CloseResult(closedPanelID: nil, closedTabs: [closedTab])
    }

    @discardableResult
    public func focusPanel(_ panelID: PanelID) -> Bool {
      guard panel(for: panelID) != nil else { return false }
      activePanelID = panelID
      return true
    }

    @discardableResult
    public func focusPanel(
      direction: PanelNavigationDirection,
      viewportSize: CGSize
    ) -> Bool {
      guard panels.count > 1 else { return false }
      let frames = Self.panelFrames(
        for: currentSplitRoot(),
        in: CGRect(origin: .zero, size: viewportSize)
      )
      guard let activeFrame = frames[activePanelID] else { return false }
      let activeCenter = Self.center(of: activeFrame)

      let candidates = frames.filter { panelID, frame in
        guard panelID != activePanelID else { return false }
        let center = Self.center(of: frame)
        switch direction {
        case .left:
          return center.x < activeCenter.x
        case .right:
          return center.x > activeCenter.x
        case .up:
          return center.y < activeCenter.y
        case .down:
          return center.y > activeCenter.y
        }
      }

      guard let target = candidates.min(by: { lhs, rhs in
        Self.scorePanelFrame(lhs.value, from: activeFrame, direction: direction)
          < Self.scorePanelFrame(rhs.value, from: activeFrame, direction: direction)
      }) else {
        return false
      }

      activePanelID = target.key
      return true
    }

    @discardableResult
    public func selectTab(_ tabID: TabID, in panelID: PanelID) -> Bool {
      guard let panel = panel(for: panelID), panel.selectTab(tabID) else {
        return false
      }
      activePanelID = panel.id
      return true
    }

    @discardableResult
    public func selectTab(direction: TabNavigationDirection) -> Bool {
      guard let panel = activePanel, panel.tabs.count > 1 else { return false }
      let currentIndex = panel.tabs.firstIndex { $0.id == panel.activeTabID } ?? 0
      let nextIndex: Int
      switch direction {
      case .previous:
        nextIndex = (currentIndex - 1 + panel.tabs.count) % panel.tabs.count
      case .next:
        nextIndex = (currentIndex + 1) % panel.tabs.count
      }
      return selectTab(panel.tabs[nextIndex].id, in: panel.id)
    }

    @discardableResult
    public func resetToPrimary(keeping keepTabID: TabID?) -> CloseResult<Payload> {
      guard let primary = primaryPanel ?? panels.first else { return .empty }
      var closedTabs: [ClosedTab<Payload>] = []

      for panel in panels where panel.id != primary.id {
        closedTabs.append(contentsOf: panel.tabs.map {
          ClosedTab(panelID: panel.id, tabID: $0.id, payload: $0.payload)
        })
      }

      panels = [primary]
      primaryPanelID = primary.id
      activePanelID = primary.id
      splitRoot = .panel(primary.id)

      if let keepTabID {
        closedTabs.append(contentsOf: primary.keepOnlyTab(keepTabID))
      }

      return CloseResult(closedPanelID: nil, closedTabs: closedTabs)
    }

    public func currentSplitRoot() -> SplitNode {
      splitRoot ?? panels.first.map { .panel($0.id) } ?? .panel(PanelID())
    }

    public func containsTab(_ tabID: TabID) -> Bool {
      allTabs.contains { $0.id == tabID }
    }

    private static func center(of rect: CGRect) -> CGPoint {
      CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func scorePanelFrame(
      _ frame: CGRect,
      from activeFrame: CGRect,
      direction: PanelNavigationDirection
    ) -> CGFloat {
      let activeCenter = center(of: activeFrame)
      let center = center(of: frame)
      let primaryDistance: CGFloat
      let crossDistance: CGFloat
      let overlaps: Bool

      switch direction {
      case .left, .right:
        primaryDistance = abs(center.x - activeCenter.x)
        crossDistance = abs(center.y - activeCenter.y)
        overlaps = frame.maxY > activeFrame.minY && frame.minY < activeFrame.maxY
      case .up, .down:
        primaryDistance = abs(center.y - activeCenter.y)
        crossDistance = abs(center.x - activeCenter.x)
        overlaps = frame.maxX > activeFrame.minX && frame.minX < activeFrame.maxX
      }

      return primaryDistance + crossDistance * 0.25 + (overlaps ? 0 : 10_000)
    }

    public static func panelFrames(
      for node: SplitNode,
      in rect: CGRect
    ) -> [PanelID: CGRect] {
      switch node {
      case .panel(let panelID):
        return [panelID: rect]
      case .split(let axis, let children):
        return splitPanelFrames(axis: axis, children: children, in: rect)
      }
    }

    private static func splitPanelFrames(
      axis: SplitAxis,
      children: [SplitNode],
      in rect: CGRect
    ) -> [PanelID: CGRect] {
      guard !children.isEmpty else { return [:] }

      var result: [PanelID: CGRect] = [:]
      let dividerSize: CGFloat = 1
      let childCount = CGFloat(children.count)

      switch axis {
      case .horizontal:
        let totalDividerWidth = dividerSize * CGFloat(max(children.count - 1, 0))
        let childWidth = max(0, rect.width - totalDividerWidth) / childCount
        var nextX = rect.minX

        for (index, child) in children.enumerated() {
          if index > 0 {
            nextX += dividerSize
          }
          let childRect = CGRect(x: nextX, y: rect.minY, width: childWidth, height: rect.height)
          result.merge(panelFrames(for: child, in: childRect), uniquingKeysWith: { current, _ in current })
          nextX += childWidth
        }

      case .vertical:
        let totalDividerHeight = dividerSize * CGFloat(max(children.count - 1, 0))
        let childHeight = max(0, rect.height - totalDividerHeight) / childCount
        var nextY = rect.minY

        for (index, child) in children.enumerated() {
          if index > 0 {
            nextY += dividerSize
          }
          let childRect = CGRect(x: rect.minX, y: nextY, width: rect.width, height: childHeight)
          result.merge(panelFrames(for: child, in: childRect), uniquingKeysWith: { current, _ in current })
          nextY += childHeight
        }
      }

      return result
    }
  }

  public enum SplitLayoutBuilder {
    public static func addingPanel(
      _ newPanelID: PanelID,
      to root: SplitNode,
      beside anchorPanelID: PanelID,
      axis: SplitAxis
    ) -> SplitNode {
      switch root {
      case .panel(let panelID):
        guard panelID == anchorPanelID else { return root }
        return .split(axis: axis, children: [.panel(panelID), .panel(newPanelID)])

      case .split(let splitAxis, let children):
        return .split(
          axis: splitAxis,
          children: children.map { child in
            guard child.containsPanel(anchorPanelID) else { return child }
            return addingPanel(newPanelID, to: child, beside: anchorPanelID, axis: axis)
          }
        )
      }
    }

    public static func removingPanel(
      _ panelID: PanelID,
      from root: SplitNode
    ) -> SplitNode? {
      switch root {
      case .panel(let currentPanelID):
        return currentPanelID == panelID ? nil : root

      case .split(let axis, let children):
        let remainingChildren = children.compactMap { removingPanel(panelID, from: $0) }
        switch remainingChildren.count {
        case 0:
          return nil
        case 1:
          return remainingChildren[0]
        default:
          return .split(axis: axis, children: remainingChildren)
        }
      }
    }

    public static func replacingPanel(
      _ currentPanelID: PanelID,
      with replacementPanelID: PanelID,
      in root: SplitNode
    ) -> SplitNode {
      switch root {
      case .panel(let panelID):
        return .panel(panelID == currentPanelID ? replacementPanelID : panelID)

      case .split(let axis, let children):
        return .split(
          axis: axis,
          children: children.map {
            replacingPanel(currentPanelID, with: replacementPanelID, in: $0)
          }
        )
      }
    }
  }
}
