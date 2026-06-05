//
//  PierreDiffRenderOptions+AgentHub.swift
//  AgentHub
//
//  Created by Assistant on 6/4/26.
//

import PierreDiffsSwift

/// Centralized `PierreDiffRenderOptions` presets so every diff surface stays
/// consistent and future tuning happens in one place.
///
/// `PierreDiffRenderOptions` was introduced in PierreDiffsSwift 1.2.0 and its
/// defaults preserve the library's historical rendering, so any surface that
/// does not opt into a preset looks exactly as it did before the upgrade.
extension PierreDiffRenderOptions {
  /// Git diff surfaces — the main split-pane `GitDiffView` and the GitHub PR
  /// review diff.
  ///
  /// Currently matches the library's historical rendering (sticky header
  /// disabled). Kept as a named preset so future diff-surface tuning happens in
  /// one place.
  ///
  /// Note: unchanged-region collapsing is already the `@pierre/diffs` default
  /// (`expandUnchanged` defaults to `false` with a built-in context threshold),
  /// so large PR diffs already collapse today. We deliberately leave
  /// `collapsedContextThreshold` at the library default to keep existing
  /// rendering unchanged.
  static let agentHubDiff = PierreDiffRenderOptions(stickyHeader: false)

  /// Raw-JSONL monitor sheet (`MonitoringSessionFileSheetView`).
  ///
  /// That sheet passes `oldContent: ""`, so every line is an "addition" and the
  /// default diff styling renders it as an all-green block. Dropping the diff
  /// indicators, intra-line highlighting, and add/remove backgrounds makes it
  /// read as a plain file viewer instead of a diff.
  static let agentHubFileViewer = PierreDiffRenderOptions(
    diffIndicators: .none,
    lineDiffType: .none,
    disableBackground: true
  )
}
