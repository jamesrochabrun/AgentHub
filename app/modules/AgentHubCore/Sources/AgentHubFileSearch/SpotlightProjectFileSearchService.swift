import CoreServices
import Foundation

public actor SpotlightProjectFileSearchService: ProjectFileSearchServiceProtocol {
  public static let shared = SpotlightProjectFileSearchService()

  private let metadataClient: any SpotlightMetadataQuerying
  private let fileChecker: any SearchableFileChecking

  public init() {
    self.init(
      metadataClient: CoreServicesSpotlightMetadataClient(),
      fileChecker: FileManagerSearchableFileChecker()
    )
  }

  init(
    metadataClient: any SpotlightMetadataQuerying,
    fileChecker: any SearchableFileChecking
  ) {
    self.metadataClient = metadataClient
    self.fileChecker = fileChecker
  }

  public func search(query: String, in projectPath: String, limit: Int) async -> [ProjectFileSearchResult] {
    guard !query.isEmpty, query.count < 200, limit > 0 else { return [] }

    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    let candidateLimit = max(limit * 8, 200)
    let metadataClient = metadataClient
    let paths = await Task.detached(priority: .userInitiated) {
      metadataClient.searchFilePaths(
        matching: query,
        in: resolvedProjectPath,
        limit: candidateLimit
      )
    }.value

    return SpotlightFileSearchRanker.rankedResults(
      paths: paths,
      query: query,
      projectPath: resolvedProjectPath,
      limit: limit,
      fileChecker: fileChecker
    )
  }

  private static func resolvedURL(for path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  }
}

protocol SpotlightMetadataQuerying: Sendable {
  func searchFilePaths(matching query: String, in projectPath: String, limit: Int) -> [String]
}

struct CoreServicesSpotlightMetadataClient: SpotlightMetadataQuerying {
  func searchFilePaths(matching query: String, in projectPath: String, limit: Int) -> [String] {
    guard limit > 0,
          let queryExpression = SpotlightQueryBuilder.expression(for: query),
          let metadataQuery = MDQueryCreate(
            kCFAllocatorDefault,
            queryExpression as CFString,
            nil,
            nil
          ) else {
      return []
    }

    MDQuerySetSearchScope(metadataQuery, [projectPath] as CFArray, 0)
    MDQuerySetMaxCount(metadataQuery, limit)
    guard MDQueryExecute(metadataQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
      MDQueryStop(metadataQuery)
      return []
    }
    defer { MDQueryStop(metadataQuery) }

    let resultCount = min(MDQueryGetResultCount(metadataQuery), limit)
    var paths: [String] = []
    var seenPaths = Set<String>()
    paths.reserveCapacity(resultCount)

    for index in 0..<resultCount {
      guard let rawItem = MDQueryGetResultAtIndex(metadataQuery, index) else {
        continue
      }

      let metadataItem = Unmanaged<MDItem>.fromOpaque(rawItem).takeUnretainedValue()
      guard let path = MDItemCopyAttribute(metadataItem, kMDItemPath as CFString) as? String,
            seenPaths.insert(path).inserted else {
        continue
      }

      paths.append(path)
    }

    return paths
  }
}

enum SpotlightQueryBuilder {
  private static let searchableAttributes = [
    "kMDItemDisplayName",
    "kMDItemFSName",
    "kMDItemPath"
  ]

  static func expression(for query: String) -> String? {
    let term = normalizedTerm(query)
    guard !term.isEmpty else { return nil }

    let pattern = "*\(escapeQuotedString(term))*"
    let clauses = searchableAttributes.map { attribute in
      "\(attribute) == \"\(pattern)\"cd"
    }
    return "(\(clauses.joined(separator: " || ")))"
  }

  private static func normalizedTerm(_ query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = trimmed.unicodeScalars.map { scalar in
      CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }
    return scalars.joined()
  }

  private static func escapeQuotedString(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

protocol SearchableFileChecking: Sendable {
  func isSearchableFile(at path: String) -> Bool
}

struct FileManagerSearchableFileChecker: SearchableFileChecking {
  func isSearchableFile(at path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
          values.isDirectory != true,
          values.isSymbolicLink != true else {
      return false
    }

    return true
  }
}

enum SpotlightFileSearchRanker {
  static func rankedResults(
    paths: [String],
    query: String,
    projectPath: String,
    limit: Int,
    fileChecker: any SearchableFileChecking
  ) -> [ProjectFileSearchResult] {
    let resolvedProjectPath = resolvedURL(for: projectPath).path
    let q = query.lowercased()

    var results: [ProjectFileSearchResult] = []
    var seenResolvedPaths = Set<String>()
    results.reserveCapacity(min(paths.count, limit))

    for rawPath in paths {
      let resolvedPath = resolvedURL(for: rawPath).path
      guard isPath(resolvedPath, within: resolvedProjectPath),
            resolvedPath != resolvedProjectPath,
            seenResolvedPaths.insert(resolvedPath).inserted,
            fileChecker.isSearchableFile(at: resolvedPath) else {
        continue
      }

      let relativePath = String(resolvedPath.dropFirst(resolvedProjectPath.count + 1))
      let name = URL(fileURLWithPath: resolvedPath).lastPathComponent
      let score = score(name: name, relativePath: relativePath, query: q)
      guard score > 0 else { continue }

      results.append(ProjectFileSearchResult(
        id: resolvedPath,
        name: name,
        relativePath: relativePath,
        absolutePath: resolvedPath,
        score: score
      ))
    }

    results.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      let nameOrder = $0.name.localizedStandardCompare($1.name)
      if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
      return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }

    return Array(results.prefix(limit))
  }

  private static func score(name: String, relativePath: String, query: String) -> Int {
    let nameLower = name.lowercased()
    let nameNoExt = (name as NSString).deletingPathExtension.lowercased()
    let pathLower = relativePath.lowercased()

    if nameNoExt == query {
      return 5000
    }

    if nameNoExt.hasPrefix(query) {
      return 4000 + (100 - min(nameLower.count, 100))
    }

    if nameLower.hasPrefix(query) {
      return 3500 + (100 - min(nameLower.count, 100))
    }

    if nameLower.contains(query), let nameRange = nameLower.range(of: query) {
      let position = nameRange.lowerBound.utf16Offset(in: nameLower)
      return 2000 + (200 - position) + (100 - min(nameLower.count, 100))
    }

    if pathLower.contains(query), let pathRange = pathLower.range(of: query) {
      let position = pathRange.lowerBound.utf16Offset(in: pathLower)
      return 1000 + (500 - min(position, 500))
    }

    return 0
  }

  private static func resolvedURL(for path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func isPath(_ path: String, within rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
  }
}
