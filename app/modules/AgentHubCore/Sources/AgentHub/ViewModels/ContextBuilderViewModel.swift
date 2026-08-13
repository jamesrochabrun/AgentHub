//
//  ContextBuilderViewModel.swift
//  AgentHub
//
//  Drives the Context Builder: file selection, per-file/total token estimates,
//  the exact assembled-block preview, and profile apply/save.
//

import Foundation
import Observation

public struct ContextSelectedFileRow: Identifiable, Equatable, Sendable {
  public var id: String { relativePath }
  /// Project-relative path for repo files; absolute path for external items.
  public let relativePath: String
  public let byteCount: Int?
  public let estimatedTokens: Int?
  /// True when the path did not resolve (stale profile entry, deleted file).
  /// Kept in the selection so saving preserves intent.
  public let isMissing: Bool
  /// True for files outside the project repository (absolute paths).
  public let isExternal: Bool
  /// True when the file exists but will be referenced by path instead of
  /// inlined (binary formats like PDFs, or oversized files).
  public let isAttachment: Bool

  public init(
    relativePath: String,
    byteCount: Int?,
    estimatedTokens: Int?,
    isMissing: Bool,
    isExternal: Bool = false,
    isAttachment: Bool = false
  ) {
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.estimatedTokens = estimatedTokens
    self.isMissing = isMissing
    self.isExternal = isExternal
    self.isAttachment = isAttachment
  }
}

@MainActor
@Observable
public final class ContextBuilderViewModel {

  // MARK: - Dependencies

  private let fileLoader: any ContextFileLoading
  private let assembler: any ContextAssembling
  private let estimator: any ContextTokenEstimating
  private let payloadThreshold: Int
  private let profileService: (any ContextProfileServiceProtocol)?
  private let fileIndexService: FileIndexService

  // MARK: - State

  public let projectPath: String
  /// The model the launch is expected to use (configured provider default),
  /// so the window percentage reflects that model's real context window.
  public let modelIdentifier: String?
  public private(set) var contextWindowTokens: Int
  public var searchQuery: String = ""
  public var searchResults: [FileSearchResult] = []
  public var isSearching: Bool = false
  public var selectedRows: [ContextSelectedFileRow] = []
  /// Pasted text stored directly in the set being edited.
  public var textSnippets: [ContextTextSnippet] = []
  public var instructions: String = ""
  public var assembledPreview: String = ""
  /// Full size of the assembled block when the preview display was truncated.
  public var previewTruncatedByteCount: Int?
  public var availableProfiles: [ContextProfile] = []

  /// Rendering megabytes into one SwiftUI `Text` freezes the main thread in
  /// CoreText layout — the preview shows at most this many characters. The
  /// launch path always assembles the full block; only the display is capped.
  public static let previewDisplayCharacterLimit = 20_000
  /// Set when the current state came from / was saved as a profile.
  public var sourceProfile: ContextProfile?

  public init(
    projectPath: String,
    initialSelection: ContextSelection? = nil,
    sourceProfile: ContextProfile? = nil,
    modelIdentifier: String? = nil,
    fileLoader: any ContextFileLoading = ContextFileLoader(),
    assembler: any ContextAssembling = ContextAssembler(),
    estimator: any ContextTokenEstimating = ContextTokenEstimator(),
    payloadThreshold: Int = ContextPayloadStore.inlineByteThreshold,
    profileService: (any ContextProfileServiceProtocol)? = nil,
    fileIndexService: FileIndexService = .shared
  ) {
    self.projectPath = projectPath
    self.modelIdentifier = modelIdentifier
    self.contextWindowTokens = ModelContextWindowResolver.window(forModelIdentifier: modelIdentifier)
    self.fileLoader = fileLoader
    self.assembler = assembler
    self.estimator = estimator
    self.payloadThreshold = payloadThreshold
    self.profileService = profileService
    self.fileIndexService = fileIndexService
    self.sourceProfile = sourceProfile
    if let initialSelection {
      selectedRows = initialSelection.files.map {
        ContextSelectedFileRow(relativePath: $0.relativePath, byteCount: nil, estimatedTokens: nil, isMissing: false)
      }
      selectedRows.append(contentsOf: initialSelection.externalPaths.map {
        ContextSelectedFileRow(
          relativePath: $0, byteCount: nil, estimatedTokens: nil, isMissing: false, isExternal: true)
      })
      textSnippets = initialSelection.textSnippets
      instructions = initialSelection.instructions
    }
  }

  // MARK: - Derived

  public var totalEstimatedTokens: Int {
    selectedRows.compactMap(\.estimatedTokens).reduce(0, +)
      + textSnippets.reduce(0) { $0 + estimator.estimatedTokens(forByteCount: $1.content.utf8.count) }
      + estimator.estimatedTokens(forByteCount: instructions.utf8.count)
  }

  /// Fraction of the model context window the selection would occupy.
  public var windowFraction: Double {
    guard contextWindowTokens > 0 else { return 0 }
    return Double(totalEstimatedTokens) / Double(contextWindowTokens)
  }

  /// True when the assembled block will be handed over as a temp-file
  /// reference instead of pasted inline.
  public var willUseFileFallback: Bool {
    let selectedBytes = selectedRows.compactMap(\.byteCount).reduce(0, +)
    let snippetBytes = textSnippets.reduce(0) { $0 + $1.content.utf8.count }
    return selectedBytes + snippetBytes + instructions.utf8.count > payloadThreshold
  }

  public var missingPaths: [String] {
    selectedRows.filter(\.isMissing).map(\.relativePath)
  }

  public var hasSelection: Bool {
    !currentSelection().isEmpty
  }

  public var profileServiceAvailable: Bool { profileService != nil }

  /// True when the loaded context set differs from the current editor state —
  /// gates "Save Changes" so it only lights up after an actual edit.
  public var hasUnsavedChanges: Bool {
    guard let sourceProfile else { return false }
    let saved = ContextSelection(
      files: sourceProfile.selection.files,
      externalPaths: sourceProfile.selection.externalPaths,
      textSnippets: sourceProfile.selection.textSnippets,
      instructions: sourceProfile.selection.instructions
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    return currentSelection() != saved
  }

  public func isSelected(relativePath: String) -> Bool {
    selectedRows.contains { $0.relativePath == relativePath }
  }

  public func currentSelection() -> ContextSelection {
    ContextSelection(
      files: selectedRows.filter { !$0.isExternal }
        .map { ContextFileSelection(relativePath: $0.relativePath) },
      externalPaths: selectedRows.filter(\.isExternal).map(\.relativePath),
      textSnippets: textSnippets,
      instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  // MARK: - Selection

  public func toggleSelection(relativePath: String) async {
    if isSelected(relativePath: relativePath) {
      selectedRows.removeAll { $0.relativePath == relativePath }
    } else {
      selectedRows.append(
        ContextSelectedFileRow(relativePath: relativePath, byteCount: nil, estimatedTokens: nil, isMissing: false))
      await refreshMetrics()
    }
  }

  public func removeSelection(relativePath: String) {
    selectedRows.removeAll { $0.relativePath == relativePath }
  }

  // MARK: - Text snippets

  public func addTextSnippet(title: String, content: String) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty, !content.isEmpty else { return }
    textSnippets.append(ContextTextSnippet(title: trimmedTitle, content: content))
  }

  public func removeTextSnippet(id: String) {
    textSnippets.removeAll { $0.id == id }
  }

  /// Adds user-picked external files (the picker multi-selects; directories
  /// are ignored — external selection is deliberately files-only).
  public func addExternalFiles(_ urls: [URL]) async {
    let existing = Set(selectedRows.map(\.relativePath))
    let newPaths = ContextFileLoader.regularFilePaths(from: urls)
      .filter { !existing.contains($0) }
    guard !newPaths.isEmpty else { return }
    selectedRows.append(contentsOf: newPaths.map {
      ContextSelectedFileRow(
        relativePath: $0, byteCount: nil, estimatedTokens: nil, isMissing: false, isExternal: true)
    })
    await refreshMetrics()
  }

  /// Refreshes byte counts / token estimates for every selected row and marks
  /// rows whose file no longer resolves.
  public func refreshMetrics() async {
    guard !selectedRows.isEmpty else { return }
    let projectPaths = selectedRows.filter { !$0.isExternal }.map(\.relativePath)
    let externalPaths = selectedRows.filter(\.isExternal).map(\.relativePath)
    let metrics = await fileLoader.fileMetrics(relativePaths: projectPaths, projectPath: projectPath)
    let externalStatuses = await fileLoader.externalFileStatuses(absolutePaths: externalPaths)

    selectedRows = selectedRows.map { row in
      if row.isExternal {
        switch externalStatuses[row.relativePath] {
        case .text(let fileMetrics):
          return ContextSelectedFileRow(
            relativePath: row.relativePath,
            byteCount: fileMetrics.byteCount,
            estimatedTokens: estimator.estimatedTokens(forByteCount: fileMetrics.byteCount),
            isMissing: false,
            isExternal: true
          )
        case .attachment:
          return ContextSelectedFileRow(
            relativePath: row.relativePath,
            byteCount: nil,
            estimatedTokens: estimator.estimatedTokens(forByteCount: row.relativePath.utf8.count),
            isMissing: false,
            isExternal: true,
            isAttachment: true
          )
        case .missing, nil:
          return ContextSelectedFileRow(
            relativePath: row.relativePath, byteCount: nil, estimatedTokens: nil,
            isMissing: true, isExternal: true)
        }
      }
      if let fileMetrics = metrics[row.relativePath] {
        return ContextSelectedFileRow(
          relativePath: row.relativePath,
          byteCount: fileMetrics.byteCount,
          estimatedTokens: estimator.estimatedTokens(forByteCount: fileMetrics.byteCount),
          isMissing: false
        )
      }
      return ContextSelectedFileRow(
        relativePath: row.relativePath, byteCount: nil, estimatedTokens: nil, isMissing: true)
    }
  }

  // MARK: - Search

  public func performSearch() async {
    let query = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else {
      searchResults = await fileIndexService.recentFiles(in: projectPath)
      return
    }
    isSearching = true
    defer { isSearching = false }
    searchResults = await fileIndexService.search(query: query, in: projectPath)
  }

  public func prepareSearchIndex() async {
    await fileIndexService.prepareSearchIndex(projectPath: projectPath)
    if searchQuery.isEmpty {
      searchResults = await fileIndexService.recentFiles(in: projectPath)
    }
  }

  // MARK: - Preview

  /// Regenerates the exact assembled block (loads full contents; on-demand only).
  public func refreshPreview() async {
    let selection = currentSelection()
    guard !selection.isEmpty else {
      assembledPreview = ""
      return
    }
    let projectLoad = await fileLoader.loadFiles(
      relativePaths: selection.files.map(\.relativePath),
      projectPath: projectPath
    )
    let externalLoad = await fileLoader.loadExternalFiles(absolutePaths: selection.externalPaths)
    let result = assembler.assemble(ContextAssemblyInput(
      files: projectLoad.loaded + externalLoad.loaded,
      missingPaths: projectLoad.missing + externalLoad.missing,
      attachmentPaths: projectLoad.attachments + externalLoad.attachments,
      textSnippets: selection.textSnippets,
      instructions: selection.instructions
    ))
    if result.block.count > Self.previewDisplayCharacterLimit {
      assembledPreview = String(result.block.prefix(Self.previewDisplayCharacterLimit))
      previewTruncatedByteCount = result.byteCount
    } else {
      assembledPreview = result.block
      previewTruncatedByteCount = nil
    }
  }

  // MARK: - Profiles

  public func loadProfiles() async {
    guard let profileService else { return }
    availableProfiles = (try? await profileService.profiles(forProjectPath: projectPath)) ?? []
  }

  /// Clears the editor to a fresh, unsaved draft (the rail's "New Context Set").
  public func startNewDraft() {
    sourceProfile = nil
    selectedRows = []
    textSnippets = []
    instructions = ""
    assembledPreview = ""
    previewTruncatedByteCount = nil
  }

  public func applyProfile(_ profile: ContextProfile) async {
    sourceProfile = profile
    instructions = profile.selection.instructions
    selectedRows = profile.selection.files.map {
      ContextSelectedFileRow(relativePath: $0.relativePath, byteCount: nil, estimatedTokens: nil, isMissing: false)
    }
    selectedRows.append(contentsOf: profile.selection.externalPaths.map {
      ContextSelectedFileRow(
        relativePath: $0, byteCount: nil, estimatedTokens: nil, isMissing: false, isExternal: true)
    })
    textSnippets = profile.selection.textSnippets
    await refreshMetrics()
  }

  @discardableResult
  public func saveAsProfile(name: String, scope: ContextProfileScope) async throws -> ContextProfile? {
    guard let profileService else { return nil }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return nil }
    let profile = ContextProfile(
      name: trimmedName,
      scope: scope,
      projectPath: projectPath,
      selection: currentSelection()
    )
    try await profileService.save(profile)
    sourceProfile = profile
    await loadProfiles()
    return profile
  }

  /// Deletes a saved context set. If it was loaded in the editor, the editor
  /// resets to a fresh draft.
  public func deleteProfile(_ profile: ContextProfile) async {
    guard let profileService else { return }
    try? await profileService.delete(id: profile.id, projectPath: projectPath)
    if sourceProfile?.id == profile.id {
      startNewDraft()
    }
    await loadProfiles()
  }

  /// Saves edits back into the context set being edited.
  public func saveEditedProfile() async throws -> ContextProfile? {
    guard let profileService, var profile = sourceProfile else { return nil }
    profile.selection = currentSelection()
    try await profileService.save(profile)
    sourceProfile = profile
    await loadProfiles()
    return profile
  }
}
