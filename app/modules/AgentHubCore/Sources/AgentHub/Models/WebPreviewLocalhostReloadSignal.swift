//
//  WebPreviewLocalhostReloadSignal.swift
//  AgentHub
//
//  Derives localhost preview reload signals from session monitor activity.
//

import Foundation

struct WebPreviewLocalhostReloadSignal: Equatable {
  let activityID: UUID
  let timestamp: Date

  enum Decision: Equatable {
    case none
    case captureBaseline(UUID)
    case reload(UUID)
  }

  static func latest(from monitorState: SessionMonitorState?) -> WebPreviewLocalhostReloadSignal? {
    guard let activity = monitorState?.recentActivities.reversed().first(where: isSuccessfulCodeChangeResult(_:)) else {
      return nil
    }

    return WebPreviewLocalhostReloadSignal(
      activityID: activity.id,
      timestamp: activity.timestamp
    )
  }

  static func decision(
    handledActivityID: UUID?,
    latestSignal: WebPreviewLocalhostReloadSignal?,
    previewStartedAt: Date
  ) -> Decision {
    guard let latestSignal else { return .none }

    if handledActivityID == latestSignal.activityID {
      return .none
    }

    guard handledActivityID == nil else {
      return .reload(latestSignal.activityID)
    }

    if latestSignal.timestamp <= previewStartedAt {
      return .captureBaseline(latestSignal.activityID)
    }

    return .reload(latestSignal.activityID)
  }

  private static func isSuccessfulCodeChangeResult(_ activity: ActivityEntry) -> Bool {
    guard case .toolResult(let name, let success) = activity.type,
          success else {
      return false
    }

    return name == CodeChangeInput.ToolType.edit.rawValue
      || name == CodeChangeInput.ToolType.write.rawValue
      || name == CodeChangeInput.ToolType.multiEdit.rawValue
  }
}
