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
    filePath: String
  ) -> MonitoringAutoOpenSidePanelKey {
    MonitoringAutoOpenSidePanelKey(
      providerRawValue: providerKind.rawValue,
      sessionID: sessionID,
      kind: .plan,
      value: filePath
    )
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
  static func candidate(
    layoutMode: HubLayoutMode,
    maximizedSessionId: String?,
    activeModuleLandingPath: String?,
    visibleItem: MonitoringAutoOpenSidePanelItem?,
    openedKeys: Set<MonitoringAutoOpenSidePanelKey>
  ) -> MonitoringAutoOpenSidePanelCandidate? {
    guard layoutMode == .single,
          maximizedSessionId == nil,
          activeModuleLandingPath == nil,
          let visibleItem else {
      return nil
    }

    if let pendingToolUse = visibleItem.state?.pendingToolUse,
       pendingToolUse.isCodeChangeTool {
      let key = MonitoringAutoOpenSidePanelKey.edits(
        providerKind: visibleItem.providerKind,
        sessionID: visibleItem.session.id,
        toolUseId: pendingToolUse.toolUseId
      )
      guard !openedKeys.contains(key) else { return nil }
      return MonitoringAutoOpenSidePanelCandidate(
        itemID: visibleItem.itemID,
        providerKind: visibleItem.providerKind,
        session: visibleItem.session,
        target: .edits,
        key: key
      )
    }

    if let activities = visibleItem.state?.recentActivities,
       let planState = PlanState.from(activities: activities) {
      let key = MonitoringAutoOpenSidePanelKey.plan(
        providerKind: visibleItem.providerKind,
        sessionID: visibleItem.session.id,
        filePath: planState.filePath
      )
      guard !openedKeys.contains(key) else { return nil }
      return MonitoringAutoOpenSidePanelCandidate(
        itemID: visibleItem.itemID,
        providerKind: visibleItem.providerKind,
        session: visibleItem.session,
        target: .plan(planState),
        key: key
      )
    }

    return nil
  }
}
