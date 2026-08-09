//
//  MeasurementsSettingsViewModel.swift
//  AgentHub
//
//  Backs the Settings tab for reviewing and deleting stored measurements.
//

import AgentHubCLIKit
import Foundation

/// One project's stored measurements, as the Settings list shows them.
public struct MeasurementProjectGroup: Identifiable, Equatable, Sendable {
  public var id: String { projectPath }

  public let projectPath: String
  public let measurements: [MeasurementRecord]

  public init(projectPath: String, measurements: [MeasurementRecord]) {
    self.projectPath = projectPath
    self.measurements = measurements
  }

  /// Last directory component, for a readable row title.
  public var displayName: String {
    let name = (projectPath as NSString).lastPathComponent
    return name.isEmpty ? projectPath : name
  }

  /// Most recent activity across the group — a re-run counts, which is why this
  /// uses `displayDate` rather than the stored creation column.
  public var lastActivityAt: Date? {
    measurements.map(\.displayDate).max()
  }

  public var runCount: Int {
    measurements.reduce(0) { $0 + $1.runs.count }
  }
}

/// Lists and deletes stored measurements.
///
/// Settings exists for the measurements the panel cannot reach: the panel only
/// shows the project of a session you currently have open, so measurements for
/// a repository you have since deleted — exactly the ones worth clearing — are
/// otherwise invisible and permanent.
///
/// Grouped by project and never by worktree: worktrees roll up to their parent
/// repository, so there is no per-worktree set to delete, and offering one would
/// mean deleting a worktree's measurements and finding the card still there.
@MainActor
@Observable
public final class MeasurementsSettingsViewModel {
  public private(set) var groups: [MeasurementProjectGroup] = []
  /// Rows whose project resolved to nothing and which no panel can ever show.
  public private(set) var unscopedCount = 0
  public private(set) var isLoading = false

  private let store: SessionMetadataStore?

  public init(store: SessionMetadataStore?) {
    self.store = store
  }

  public var isEmpty: Bool {
    groups.isEmpty && unscopedCount == 0
  }

  public var totalCount: Int {
    groups.reduce(0) { $0 + $1.measurements.count } + unscopedCount
  }

  public func load() async {
    guard let store else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let records = try await store.getAllMeasurements()
      let decoded = records.compactMap { record -> (String, MeasurementRecord)? in
        guard let measurement = try? record.decodedMeasurement() else { return nil }
        return (record.projectPath, measurement)
      }

      unscopedCount = decoded.filter { $0.0.isEmpty }.count
      groups = Self.grouped(decoded.filter { !$0.0.isEmpty })
    } catch {
      AppLogger.session.error("Failed to load measurements for settings: \(error.localizedDescription)")
    }
  }

  public func deleteMeasurement(id: String) async {
    guard let store else { return }
    do {
      try await store.deleteMeasurement(id: id)
      await load()
    } catch {
      AppLogger.session.error("Failed to delete measurement: \(error.localizedDescription)")
    }
  }

  public func deleteAll(inProjectPath projectPath: String) async {
    guard let store else { return }
    do {
      try await store.deleteAllMeasurements(forProjectPath: projectPath)
      await load()
    } catch {
      AppLogger.session.error("Failed to delete project measurements: \(error.localizedDescription)")
    }
  }

  public func sweepUnscoped() async {
    guard let store else { return }
    do {
      try await store.deleteUnscopedMeasurements()
      await load()
    } catch {
      AppLogger.session.error("Failed to sweep unscoped measurements: \(error.localizedDescription)")
    }
  }

  /// Groups by project, most recently active project first, and newest
  /// measurement first within each.
  static func grouped(_ decoded: [(String, MeasurementRecord)]) -> [MeasurementProjectGroup] {
    Dictionary(grouping: decoded, by: \.0)
      .map { projectPath, entries in
        MeasurementProjectGroup(
          projectPath: projectPath,
          measurements: entries.map(\.1).sorted { $0.displayDate > $1.displayDate }
        )
      }
      .sorted {
        switch ($0.lastActivityAt, $1.lastActivityAt) {
        case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
        default: return $0.projectPath < $1.projectPath
        }
      }
  }
}
