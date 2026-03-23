//
//  WebPreviewExternalRecovery.swift
//  AgentHub
//
//  Encapsulates how preview should recover when an agent-provided localhost
//  server cannot be loaded.
//

import Foundation

struct WebPreviewExternalRecovery: Equatable {
  let resolution: WebPreviewResolution

  static func initial(projectPath: String) -> WebPreviewExternalRecovery {
    WebPreviewExternalRecovery(resolution: .devServer(projectPath: projectPath))
  }

  static func recovered(
    agentURL: URL,
    error: String,
    staticPreviewResolution: WebPreviewResolution
  ) -> WebPreviewExternalRecovery {
    if case .directFile = staticPreviewResolution {
      return WebPreviewExternalRecovery(resolution: staticPreviewResolution)
    }

    let reason = """
      Could not load \(agentURL.absoluteString).
      \(error)

      No static HTML fallback was found in this project.
      """

    return WebPreviewExternalRecovery(resolution: .noContent(reason: reason))
  }
}
