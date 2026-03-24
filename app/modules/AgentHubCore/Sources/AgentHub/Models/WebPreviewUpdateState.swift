//
//  WebPreviewUpdateState.swift
//  AgentHub
//
//  Manual update state for the web preview footer.
//

import Foundation

@MainActor
enum WebPreviewUpdateState: Equatable {
  case hidden
  case available(detail: String)
  case unavailable(detail: String)

  static func resolve(
    resolution: WebPreviewResolution?,
    serverState: DevServerState,
    isEditMode: Bool
  ) -> WebPreviewUpdateState {
    guard isEditMode else {
      return .hidden
    }

    switch resolution {
    case .directFile:
      return WebPreviewUpdateState.available(detail: "Design and code preview updates are manual. Save changes, then press Reload.")

    case .devServer:
      switch serverState {
      case .ready:
        return WebPreviewUpdateState.available(detail: "Design and code preview updates are manual. Save changes, then press Reload.")
      case .failed:
        return WebPreviewUpdateState.unavailable(detail: "Reload is unavailable while the preview server is offline.")
      case .detecting, .starting, .waitingForReady:
        return WebPreviewUpdateState.unavailable(detail: "Reload will be available when the preview finishes loading.")
      case .stopping:
        return WebPreviewUpdateState.unavailable(detail: "Reload is unavailable while the preview server stops.")
      case .idle:
        return WebPreviewUpdateState.unavailable(detail: "Reload will be available when the preview is ready.")
      }

    case .noContent(let reason):
      return WebPreviewUpdateState.unavailable(detail: reason)

    case nil:
      return WebPreviewUpdateState.unavailable(detail: "Detecting preview configuration…")
    }
  }

  var detailText: String {
    switch self {
    case .hidden:
      ""
    case .available(let detail), .unavailable(let detail):
      detail
    }
  }

  var isVisible: Bool {
    switch self {
    case .hidden:
      false
    case .available, .unavailable:
      true
    }
  }

  var isEnabled: Bool {
    switch self {
    case .available:
      true
    case .hidden, .unavailable:
      false
    }
  }

  func performUpdate(
    flushPendingWrites: () async -> Void,
    reload: () -> Void
  ) async {
    guard isEnabled else { return }
    await flushPendingWrites()
    reload()
  }
}
