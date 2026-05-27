import Foundation

public struct ProjectFileSearchResponse: Sendable, Equatable {
  public let results: [ProjectFileSearchResult]
  public let candidateCount: Int
  public let elapsedSeconds: TimeInterval

  public init(
    results: [ProjectFileSearchResult],
    candidateCount: Int,
    elapsedSeconds: TimeInterval
  ) {
    self.results = results
    self.candidateCount = candidateCount
    self.elapsedSeconds = elapsedSeconds
  }
}

public protocol ProjectFileSearchServiceProtocol: Sendable {
  func search(query: String, in projectPath: String, limit: Int) async -> [ProjectFileSearchResult]
  func searchWithDiagnostics(query: String, in projectPath: String, limit: Int) async -> ProjectFileSearchResponse
}

public extension ProjectFileSearchServiceProtocol {
  func searchWithDiagnostics(query: String, in projectPath: String, limit: Int) async -> ProjectFileSearchResponse {
    let start = Date()
    let results = await search(query: query, in: projectPath, limit: limit)
    return ProjectFileSearchResponse(
      results: results,
      candidateCount: results.count,
      elapsedSeconds: Date().timeIntervalSince(start)
    )
  }
}
