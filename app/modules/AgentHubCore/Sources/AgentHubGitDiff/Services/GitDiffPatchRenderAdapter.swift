import Foundation

public enum GitDiffPatchRenderAdapter {
  private static let omittedSectionMarker = "..."

  public static func renderedPayload(
    from patch: String,
    limitedContextReason: String
  ) -> GitDiffRenderPayload? {
    guard let renderedDiff = renderedDiff(from: patch) else { return nil }

    return GitDiffRenderPayload(
      oldContent: renderedDiff.oldContent,
      newContent: renderedDiff.newContent,
      isLimitedContext: true,
      limitedContextReason: limitedContextReason
    )
  }

  public static func renderedDiff(from patch: String) -> (oldContent: String, newContent: String)? {
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

      guard didParseHunk else { continue }

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
    return (
      oldContent: oldLines.joined(separator: "\n"),
      newContent: newLines.joined(separator: "\n")
    )
  }
}
