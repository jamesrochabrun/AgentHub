//
//  MonitoringAutoOpenSidePanelPolicy.swift
//  AgentHub
//

import Foundation

enum MonitoringAutoOpenSidePanelKind: String, Equatable, Hashable, Sendable {
  case edits
  case plan
}

struct MonitoringAutoOpenSidePanelKey: Equatable, Hashable, Sendable {
  let providerRawValue: String
  let sessionID: String
  let kind: MonitoringAutoOpenSidePanelKind
  let value: String

  static func edits(
    providerKind: SessionProviderKind,
    sessionID: String,
    toolUseId: String
  ) -> MonitoringAutoOpenSidePanelKey {
    MonitoringAutoOpenSidePanelKey(
      providerRawValue: providerKind.rawValue,
      sessionID: sessionID,
      kind: .edits,
      value: toolUseId
    )
  }

  static func plan(
    providerKind: SessionProviderKind,
    sessionID: String,
    filePath: String,
    detectedAt: Date? = nil
  ) -> MonitoringAutoOpenSidePanelKey {
    MonitoringAutoOpenSidePanelKey(
      providerRawValue: providerKind.rawValue,
      sessionID: sessionID,
      kind: .plan,
      value: detectedAt.map { "\(filePath)#\(Self.timestampKeyValue(for: $0))" } ?? filePath
    )
  }

  private static func timestampKeyValue(for date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }
}

enum MonitoringAutoOpenSidePanelTarget: Equatable, Sendable {
  case edits
  case plan(PlanState)

  var kind: MonitoringAutoOpenSidePanelKind {
    switch self {
    case .edits:
      return .edits
    case .plan:
      return .plan
    }
  }
}

struct MonitoringAutoOpenSidePanelItem: Equatable, Sendable {
  let itemID: String
  let providerKind: SessionProviderKind
  let session: CLISession
  let state: SessionMonitorState?

  init(
    itemID: String,
    providerKind: SessionProviderKind,
    session: CLISession,
    state: SessionMonitorState?
  ) {
    self.itemID = itemID
    self.providerKind = providerKind
    self.session = session
    self.state = state
  }
}

struct MonitoringAutoOpenSidePanelCandidate: Equatable, Sendable {
  let itemID: String
  let providerKind: SessionProviderKind
  let session: CLISession
  let target: MonitoringAutoOpenSidePanelTarget
  let key: MonitoringAutoOpenSidePanelKey
}

enum MonitoringAutoOpenSidePanelPolicy {
  static func keys(
    for item: MonitoringAutoOpenSidePanelItem
  ) -> Set<MonitoringAutoOpenSidePanelKey> {
    var keys: Set<MonitoringAutoOpenSidePanelKey> = []
    if let editsKey = editsKey(for: item) {
      keys.insert(editsKey)
    }
    if let planKey = planCandidateComponents(for: item)?.key {
      keys.insert(planKey)
    }
    return keys
  }

  static func candidate(
    layoutMode: HubLayoutMode,
    maximizedSessionId: String?,
    activeModuleLandingPath: String?,
    visibleItem: MonitoringAutoOpenSidePanelItem?,
    openedKeys: Set<MonitoringAutoOpenSidePanelKey>,
    detectedAfter: Date? = nil
  ) -> MonitoringAutoOpenSidePanelCandidate? {
    guard layoutMode == .single,
          maximizedSessionId == nil,
          activeModuleLandingPath == nil,
          let visibleItem else {
      return nil
    }

    if let editsCandidate = editsCandidateComponents(for: visibleItem) {
      let key = editsCandidate.key
      guard shouldAutoOpen(detectedAt: editsCandidate.detectedAt, detectedAfter: detectedAfter) else {
        return nil
      }
      guard !openedKeys.contains(key) else { return nil }
      return MonitoringAutoOpenSidePanelCandidate(
        itemID: visibleItem.itemID,
        providerKind: visibleItem.providerKind,
        session: visibleItem.session,
        target: .edits,
        key: key
      )
    }

    if let planCandidate = planCandidateComponents(for: visibleItem) {
      let key = planCandidate.key
      guard shouldAutoOpen(detectedAt: planCandidate.detectedAt, detectedAfter: detectedAfter) else {
        return nil
      }
      guard !openedKeys.contains(key) else { return nil }
      return MonitoringAutoOpenSidePanelCandidate(
        itemID: visibleItem.itemID,
        providerKind: visibleItem.providerKind,
        session: visibleItem.session,
        target: .plan(planCandidate.planState),
        key: key
      )
    }

    return nil
  }

  private static func editsKey(
    for item: MonitoringAutoOpenSidePanelItem
  ) -> MonitoringAutoOpenSidePanelKey? {
    editsCandidateComponents(for: item)?.key
  }

  private static func editsCandidateComponents(
    for item: MonitoringAutoOpenSidePanelItem
  ) -> (key: MonitoringAutoOpenSidePanelKey, detectedAt: Date)? {
    guard let pendingToolUse = item.state?.pendingToolUse,
          pendingToolUse.isCodeChangeTool else {
      return nil
    }

    return (
      MonitoringAutoOpenSidePanelKey.edits(
        providerKind: item.providerKind,
        sessionID: item.session.id,
        toolUseId: pendingToolUse.toolUseId
      ),
      pendingToolUse.timestamp
    )
  }

  private static func planCandidateComponents(
    for item: MonitoringAutoOpenSidePanelItem
  ) -> (key: MonitoringAutoOpenSidePanelKey, planState: PlanState, detectedAt: Date)? {
    guard let activities = item.state?.recentActivities,
          let planActivity = planActivity(from: activities) else {
      return nil
    }

    return (
      MonitoringAutoOpenSidePanelKey.plan(
        providerKind: item.providerKind,
        sessionID: item.session.id,
        filePath: planActivity.planState.filePath,
        detectedAt: planActivity.detectedAt
      ),
      planActivity.planState,
      planActivity.detectedAt
    )
  }

  private static func planActivity(
    from activities: [ActivityEntry]
  ) -> (planState: PlanState, detectedAt: Date)? {
    for activity in activities.reversed() {
      guard case .toolUse(let name) = activity.type,
            (name == "Write" || name == "Edit"),
            let input = activity.toolInput,
            (input.toolType == .write || input.toolType == .edit) else {
        continue
      }

      if input.filePath.contains("/.claude/plans/") && input.filePath.hasSuffix(".md") {
        return (PlanState(filePath: input.filePath), activity.timestamp)
      }
    }

    return nil
  }

  private static func shouldAutoOpen(detectedAt: Date, detectedAfter: Date?) -> Bool {
    guard let detectedAfter else { return true }
    return detectedAt > detectedAfter
  }
}
