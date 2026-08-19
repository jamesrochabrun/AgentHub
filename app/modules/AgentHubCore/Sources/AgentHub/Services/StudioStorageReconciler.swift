import Foundation

/// Keeps the served-document cache honest with the database.
///
/// The database is the source of truth and the `studio/{project}/{id}/` tree
/// is derived from it, so reconcile means: drop directories with no row (a
/// crash between the two deletes, or a row that vanished), and leave everything
/// else alone. Missing documents for live rows are rewritten lazily by the
/// library when the project loads — never here, which keeps this pure and cheap.
public struct StudioStorageReconciler: Sendable {
  public struct Report: Equatable, Sendable {
    public var removedArtifactDirectories: Int = 0
    public var removedEmptyProjectDirectories: Int = 0
  }

  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL
  }

  /// `knownDirectoryNames` are the on-disk artifact directory names the
  /// database vouches for (`StudioDocumentWriter.artifactDirectoryName`).
  @discardableResult
  public func reconcile(knownDirectoryNames: Set<String>) -> Report {
    var report = Report()
    let fileManager = FileManager.default
    guard let projects = try? fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return report
    }

    for project in projects {
      guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
      let artifacts = (try? fileManager.contentsOfDirectory(
        at: project,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []

      for artifact in artifacts {
        guard (try? artifact.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        if !knownDirectoryNames.contains(artifact.lastPathComponent) {
          if (try? fileManager.removeItem(at: artifact)) != nil {
            report.removedArtifactDirectories += 1
          }
        }
      }

      let remaining = (try? fileManager.contentsOfDirectory(atPath: project.path)) ?? []
      if remaining.filter({ !$0.hasPrefix(".") }).isEmpty {
        if (try? fileManager.removeItem(at: project)) != nil {
          report.removedEmptyProjectDirectories += 1
        }
      }
    }
    return report
  }

  /// Bytes on disk under one artifact directory, for the Settings view.
  public static func directorySize(at url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else {
      return 0
    }
    var total: Int64 = 0
    for case let file as URL in enumerator {
      total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }
}
