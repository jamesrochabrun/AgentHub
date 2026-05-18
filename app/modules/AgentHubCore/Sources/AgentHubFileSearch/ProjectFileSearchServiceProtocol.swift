import Foundation

public protocol ProjectFileSearchServiceProtocol: Sendable {
  func search(query: String, in projectPath: String, limit: Int) async -> [ProjectFileSearchResult]
}

