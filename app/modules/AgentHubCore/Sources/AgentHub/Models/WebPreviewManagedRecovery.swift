//
//  WebPreviewManagedRecovery.swift
//  AgentHub
//
//  Encapsulates how preview should recover when AgentHub's managed dev server
//  dies after the preview has already connected.
//

import Foundation

struct WebPreviewManagedRecovery: Equatable {
  let resolution: WebPreviewResolution
  let failureMessage: String

  static func recovered(
    projectPath: String,
    failedURL: URL,
    error: String
  ) -> WebPreviewManagedRecovery {
    let failureMessage = """
      Could not load \(failedURL.absoluteString).
      \(error)
      """

    return WebPreviewManagedRecovery(
      resolution: .devServer(projectPath: projectPath),
      failureMessage: failureMessage
    )
  }
}
