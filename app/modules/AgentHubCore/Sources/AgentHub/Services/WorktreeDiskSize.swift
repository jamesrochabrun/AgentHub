import Foundation

/// Computes the approximate on-disk footprint for a worktree directory.
///
/// The walk is tolerant of unreadable entries and does not descend into
/// symlinked subtrees, so out-of-tree caches are not double-counted. Hidden
/// entries are included because build products such as `.build` and `.swiftpm`
/// are often the bulk of a worktree's reclaimable space.
enum WorktreeDiskSize {
  static func bytes(at url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey,
      .isSymbolicLinkKey,
      .totalFileAllocatedSizeKey,
      .fileAllocatedSizeKey,
    ]

    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: Array(keys),
      options: []
    ) else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      do {
        let values = try fileURL.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
          enumerator.skipDescendants()
        }
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
      } catch {
        continue
      }
    }

    return total
  }
}
