//
//  GitHubContextDragPayload.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation
import UniformTypeIdentifiers

extension UTType {
  static let agentHubGitHubContextItem = UTType(exportedAs: "com.agenthub.github.context-item")
}

struct GitHubContextDragPayload: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case pullRequest
    case issue
  }

  static let typeIdentifier = UTType.agentHubGitHubContextItem.identifier

  let kind: Kind
  let number: Int
  let title: String
  let url: String

  init(kind: Kind, number: Int, title: String, url: String) {
    self.kind = kind
    self.number = number
    self.title = title
    self.url = url
  }

  init(pullRequest: GitHubPullRequest) {
    self.init(
      kind: .pullRequest,
      number: pullRequest.number,
      title: pullRequest.title,
      url: pullRequest.url
    )
  }

  init(issue: GitHubIssue) {
    self.init(
      kind: .issue,
      number: issue.number,
      title: issue.title,
      url: issue.url
    )
  }

  var commandText: String {
    switch kind {
    case .pullRequest:
      "/review \(url)"
    case .issue:
      "fix \(url)"
    }
  }

  func makeItemProvider() -> NSItemProvider {
    let provider = NSItemProvider()

    if let data = try? JSONEncoder().encode(self) {
      provider.registerDataRepresentation(
        forTypeIdentifier: Self.typeIdentifier,
        visibility: .all
      ) { completion in
        completion(data, nil)
        return nil
      }
    }

    if let data = commandText.data(using: .utf8) {
      provider.registerDataRepresentation(
        forTypeIdentifier: UTType.utf8PlainText.identifier,
        visibility: .all
      ) { completion in
        completion(data, nil)
        return nil
      }
    }

    return provider
  }

  static func load(from provider: NSItemProvider, completion: @escaping (GitHubContextDragPayload?) -> Void) {
    provider.loadDataRepresentation(forTypeIdentifier: Self.typeIdentifier) { data, _ in
      guard let data,
            let payload = try? JSONDecoder().decode(GitHubContextDragPayload.self, from: data) else {
        completion(nil)
        return
      }

      completion(payload)
    }
  }
}
