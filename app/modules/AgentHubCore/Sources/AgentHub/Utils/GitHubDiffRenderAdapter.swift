//
//  GitHubDiffRenderAdapter.swift
//  AgentHub
//
//  Adapts GitHub unified patch text into old/new buffers for PierreDiffsSwift.
//

import Foundation

struct GitHubRenderedDiff: Equatable, Sendable {
  let oldContent: String
  let newContent: String
}

enum GitHubDiffRenderAdapter {
  private static let omittedSectionMarker = "..."

  static func renderedDiff(from patch: String) -> GitHubRenderedDiff? {
    guard !patch.isEmpty else { return nil }

    let lines = patch.components(separatedBy: "\n")
    var oldLines: [String] = []
    var newLines: [String] = []
    var didParseHunk = false
    var hunkCount = 0

    for line in lines {
      if line.hasPrefix("@@") {
        if hunkCount > 0 && (!oldLines.isEmpty || !newLines.isEmpty) {
          oldLines.append(omittedSectionMarker)
          newLines.append(omittedSectionMarker)
        }
        hunkCount += 1
        didParseHunk = true
        continue
      }

      guard didParseHunk else {
        continue
      }

      if line.hasPrefix("\\ No newline at end of file") {
        continue
      }

      if line.hasPrefix("+") && !line.hasPrefix("+++") {
        newLines.append(String(line.dropFirst()))
      } else if line.hasPrefix("-") && !line.hasPrefix("---") {
        oldLines.append(String(line.dropFirst()))
      } else if line.hasPrefix(" ") {
        let content = String(line.dropFirst())
        oldLines.append(content)
        newLines.append(content)
      }
    }

    guard didParseHunk else { return nil }

    return GitHubRenderedDiff(
      oldContent: oldLines.joined(separator: "\n"),
      newContent: newLines.joined(separator: "\n")
    )
  }
}
