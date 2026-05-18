import Foundation

public struct ProjectFileSearchResult: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let relativePath: String
  public let absolutePath: String
  public let score: Int

  public init(
    id: String,
    name: String,
    relativePath: String,
    absolutePath: String,
    score: Int
  ) {
    self.id = id
    self.name = name
    self.relativePath = relativePath
    self.absolutePath = absolutePath
    self.score = score
  }
}

