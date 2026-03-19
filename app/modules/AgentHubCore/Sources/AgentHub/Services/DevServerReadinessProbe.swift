//
//  DevServerReadinessProbe.swift
//  AgentHub
//
//  Polls loopback candidates until a dev server becomes reachable.
//

import Foundation

enum DevServerReadinessProbeResult: Equatable, Sendable {
  case ready(URL)
  case timedOut
  case stale
}

actor DevServerReadinessProbe {
  private var candidateURLs: [URL]

  init(expectedURL: URL) {
    self.candidateURLs = [expectedURL]
  }

  init(expectedURLs: [URL]) {
    self.candidateURLs = Array(expectedURLs)
  }

  func registerCandidate(_ url: URL) {
    guard WebPreviewNavigationPolicy.isAllowedLoopbackURL(url),
          !candidateURLs.contains(url) else {
      return
    }

    candidateURLs.append(url)
  }

  func waitUntilReady(
    timeout: Duration = .seconds(30),
    pollInterval: Duration = .milliseconds(250),
    probe: @escaping @Sendable (URL) async -> Bool,
    isCurrent: @escaping @Sendable () async -> Bool
  ) async -> DevServerReadinessProbeResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
      if await !isCurrent() {
        return .stale
      }

      let urls = candidateURLs
      let readyURL: URL? = await withTaskGroup(of: URL?.self, returning: URL?.self) { group in
        for url in urls {
          group.addTask { await probe(url) ? url : nil }
        }
        for await result in group {
          if let url = result {
            group.cancelAll()
            return url
          }
        }
        return nil
      }

      if let url = readyURL {
        return await isCurrent() ? .ready(url) : .stale
      }

      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        return .stale
      }
    }

    return await isCurrent() ? .timedOut : .stale
  }
}
