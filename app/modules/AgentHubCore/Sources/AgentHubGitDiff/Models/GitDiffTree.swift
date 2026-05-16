import Foundation

public struct GitDiffTreeResult: Equatable, Sendable {
  public let nodes: [GitDiffTreeNode]
  public let commonPrefix: String
  public let allFolderPaths: Set<String>

  public init(nodes: [GitDiffTreeNode], commonPrefix: String, allFolderPaths: Set<String>) {
    self.nodes = nodes
    self.commonPrefix = commonPrefix
    self.allFolderPaths = allFolderPaths
  }
}

public struct GitDiffTreeNode: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let fullPath: String
  public let file: GitDiffFileEntry?
  public let children: [GitDiffTreeNode]

  public var isFolder: Bool { file == nil }

  public init(name: String, fullPath: String, file: GitDiffFileEntry?, children: [GitDiffTreeNode] = []) {
    self.name = name
    self.fullPath = fullPath
    self.file = file
    self.children = children
    self.id = "\(file == nil ? "folder" : "file"):\(fullPath)"
  }
}

public enum GitDiffTreeBuilder {
  public static func build(from files: [GitDiffFileEntry]) -> GitDiffTreeResult {
    guard !files.isEmpty else {
      return GitDiffTreeResult(nodes: [], commonPrefix: "", allFolderPaths: [])
    }

    let commonComponents = findCommonPrefix(from: files)
    let commonPrefix = commonComponents.joined(separator: "/")
    let stripCount = commonComponents.count

    let root = MutableGitDiffTreeNode(name: "", fullPath: "", file: nil)
    var allFolderPaths: Set<String> = []

    for file in files {
      let allComponents = file.relativePath.components(separatedBy: "/")
      let pathComponents = Array(allComponents.dropFirst(stripCount))

      var currentNode = root
      var currentPath = ""

      for (index, component) in pathComponents.enumerated() {
        let isLastComponent = index == pathComponents.count - 1
        currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"

        if isLastComponent {
          currentNode.childrenDict[component] = MutableGitDiffTreeNode(
            name: component,
            fullPath: currentPath,
            file: file
          )
        } else {
          if currentNode.childrenDict[component] == nil {
            currentNode.childrenDict[component] = MutableGitDiffTreeNode(
              name: component,
              fullPath: currentPath,
              file: nil
            )
          }
          allFolderPaths.insert(currentPath)
          if let nextNode = currentNode.childrenDict[component] {
            currentNode = nextNode
          }
        }
      }
    }

    return GitDiffTreeResult(
      nodes: sortNodes(from: root.childrenDict),
      commonPrefix: commonPrefix,
      allFolderPaths: allFolderPaths
    )
  }

  private static func findCommonPrefix(from files: [GitDiffFileEntry]) -> [String] {
    guard let first = files.first else { return [] }

    var commonComponents = Array(first.relativePath.components(separatedBy: "/").dropLast())

    for file in files.dropFirst() {
      let components = Array(file.relativePath.components(separatedBy: "/").dropLast())
      var matchCount = 0

      for (lhs, rhs) in zip(commonComponents, components) {
        guard lhs == rhs else { break }
        matchCount += 1
      }

      commonComponents = Array(commonComponents.prefix(matchCount))
      if commonComponents.isEmpty { break }
    }

    return commonComponents
  }

  private static func sortNodes(from dict: [String: MutableGitDiffTreeNode]) -> [GitDiffTreeNode] {
    dict.values
      .map { node in
        GitDiffTreeNode(
          name: node.name,
          fullPath: node.fullPath,
          file: node.file,
          children: sortNodes(from: node.childrenDict)
        )
      }
      .sorted { lhs, rhs in
        if lhs.isFolder != rhs.isFolder {
          return lhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }
}

private final class MutableGitDiffTreeNode {
  let name: String
  let fullPath: String
  let file: GitDiffFileEntry?
  var childrenDict: [String: MutableGitDiffTreeNode] = [:]

  init(name: String, fullPath: String, file: GitDiffFileEntry?) {
    self.name = name
    self.fullPath = fullPath
    self.file = file
  }
}
