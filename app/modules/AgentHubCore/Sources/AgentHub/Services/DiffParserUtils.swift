//
//  DiffParserUtils.swift
//  AgentHub
//
//  Created by Assistant on 1/30/26.
//

import Foundation

/// Parsed file diff from unified diff output
public struct ParsedFileDiff: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// The file path from the diff header
  public let filePath: String
  /// The raw unified diff content for this file
  public let diffContent: String
  /// Number of lines added
  public let additions: Int
  /// Number of lines deleted
  public let deletions: Int
  /// Whether this is a new file
  public let isNewFile: Bool
  /// Whether this is a deleted file
  public let isDeletedFile: Bool
  /// Whether this is a binary file
  public let isBinaryFile: Bool

  /// File name extracted from path
  public var fileName: String {
    URL(fileURLWithPath: filePath).lastPathComponent
  }

  /// Directory path (without file name)
  public var directoryPath: String {
    URL(fileURLWithPath: filePath).deletingLastPathComponent().path
  }

  public init(
    id: UUID = UUID(),
    filePath: String,
    diffContent: String,
    additions: Int,
    deletions: Int,
    isNewFile: Bool = false,
    isDeletedFile: Bool = false,
    isBinaryFile: Bool = false
  ) {
    self.id = id
    self.filePath = filePath
    self.diffContent = diffContent
    self.additions = additions
    self.deletions = deletions
    self.isNewFile = isNewFile
    self.isDeletedFile = isDeletedFile
    self.isBinaryFile = isBinaryFile
  }
}

/// Utility for parsing unified diff output from git
public enum DiffParserUtils {

  /// Parses unified diff output into structured file diffs
  /// - Parameter diffOutput: Raw unified diff output from `git diff`
  /// - Returns: Array of parsed file diffs
  public static func parse(diffOutput: String) -> [ParsedFileDiff] {
    guard !diffOutput.isEmpty else { return [] }

    var results: [ParsedFileDiff] = []
    let lines = diffOutput.components(separatedBy: "\n")

    var currentFilePath: String?
    var currentDiffLines: [String] = []
    var currentAdditions = 0
    var currentDeletions = 0
    var isNewFile = false
    var isDeletedFile = false
    var isBinaryFile = false

    func flushCurrentFile() {
      if let path = currentFilePath, !currentDiffLines.isEmpty {
        results.append(ParsedFileDiff(
          filePath: path,
          diffContent: currentDiffLines.joined(separator: "\n"),
          additions: currentAdditions,
          deletions: currentDeletions,
          isNewFile: isNewFile,
          isDeletedFile: isDeletedFile,
          isBinaryFile: isBinaryFile
        ))
      }
      currentFilePath = nil
      currentDiffLines = []
      currentAdditions = 0
      currentDeletions = 0
      isNewFile = false
      isDeletedFile = false
      isBinaryFile = false
    }

    for line in lines {
      // New file header: "diff --git a/path b/path"
      if line.hasPrefix("diff --git ") {
        flushCurrentFile()
        // Extract path from "diff --git a/path b/path"
        if let bPath = extractBPath(from: line) {
          currentFilePath = bPath
        }
        currentDiffLines.append(line)
        continue
      }

      // Check for new file mode
      if line.hasPrefix("new file mode") {
        isNewFile = true
        currentDiffLines.append(line)
        continue
      }

      // Check for deleted file mode
      if line.hasPrefix("deleted file mode") {
        isDeletedFile = true
        currentDiffLines.append(line)
        continue
      }

      // Check for binary file
      if line.hasPrefix("Binary files") {
        isBinaryFile = true
        currentDiffLines.append(line)
        continue
      }

      // Count additions and deletions (lines starting with + or - that are actual content)
      if line.hasPrefix("+") && !line.hasPrefix("+++") {
        currentAdditions += 1
      } else if line.hasPrefix("-") && !line.hasPrefix("---") {
        currentDeletions += 1
      }

      // Accumulate diff lines
      if currentFilePath != nil {
        currentDiffLines.append(line)
      }
    }

    // Flush the last file
    flushCurrentFile()

    return results
  }

  /// Extracts the "b/" path from a git diff header line
  /// Input: "diff --git a/path/to/file.swift b/path/to/file.swift"
  /// Output: "path/to/file.swift"
  private static func extractBPath(from diffLine: String) -> String? {
    // Handle renamed files: "diff --git a/old/path b/new/path"
    // We want the "b/" path (the new path)
    let pattern = #" b/(.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
            in: diffLine,
            range: NSRange(diffLine.startIndex..., in: diffLine)
          ),
          let range = Range(match.range(at: 1), in: diffLine) else {
      return nil
    }
    return String(diffLine[range])
  }

  /// Extracts old and new content from unified diff
  /// This reconstructs the file contents from the diff hunks
  /// - Parameters:
  ///   - diffContent: The unified diff content for a single file
  ///   - oldContent: Optional original file content (for more accurate reconstruction)
  /// - Returns: Tuple of (oldContent, newContent) reconstructed from diff
  public static func extractContentsFromDiff(_ diffContent: String) -> (old: String, new: String) {
    var oldLines: [String] = []
    var newLines: [String] = []
    var inHunk = false

    let lines = diffContent.components(separatedBy: "\n")

    for line in lines {
      // Skip diff headers
      if line.hasPrefix("diff --git") ||
          line.hasPrefix("index ") ||
          line.hasPrefix("---") ||
          line.hasPrefix("+++") ||
          line.hasPrefix("new file") ||
          line.hasPrefix("deleted file") ||
          line.hasPrefix("old mode") ||
          line.hasPrefix("new mode") {
        continue
      }

      // Hunk header: @@ -start,count +start,count @@
      if line.hasPrefix("@@") {
        inHunk = true
        continue
      }

      guard inHunk else { continue }

      if line.hasPrefix("-") {
        // Removed line - only in old
        oldLines.append(String(line.dropFirst()))
      } else if line.hasPrefix("+") {
        // Added line - only in new
        newLines.append(String(line.dropFirst()))
      } else if line.hasPrefix(" ") {
        // Context line - in both
        let contextLine = String(line.dropFirst())
        oldLines.append(contextLine)
        newLines.append(contextLine)
      } else if line.isEmpty {
        // Empty line in diff (context)
        oldLines.append("")
        newLines.append("")
      }
    }

    return (old: oldLines.joined(separator: "\n"), new: newLines.joined(separator: "\n"))
  }

  /// Converts ParsedFileDiff array to GitDiffFileEntry array for compatibility
  /// - Parameters:
  ///   - parsedDiffs: Array of parsed file diffs
  ///   - gitRoot: Git repository root path
  /// - Returns: Array of GitDiffFileEntry for use with existing UI
  public static func toGitDiffFileEntries(
    _ parsedDiffs: [ParsedFileDiff],
    gitRoot: String
  ) -> [GitDiffFileEntry] {
    parsedDiffs.map { diff in
      let fullPath = (gitRoot as NSString).appendingPathComponent(diff.filePath)
      return GitDiffFileEntry(
        id: diff.id,
        filePath: fullPath,
        relativePath: diff.filePath,
        additions: diff.additions,
        deletions: diff.deletions
      )
    }
  }
}
