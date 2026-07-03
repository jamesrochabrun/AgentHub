//
//  WebPreviewDirectCSSWriteCoordinator.swift
//  AgentHub
//
//  Applies a proven Tier-1 CSS declaration edit to disk. Re-reads the file and
//  verifies the SHA-256 baseline immediately before writing so a concurrent
//  agent edit is never clobbered; the splice itself enforces the
//  CSSSourceEditor post-conditions before any bytes are written.
//

import Foundation

enum DirectWriteOutcome: Equatable, Sendable {
  case written(newSHA256: String)
  case baselineDrift
  case editFailed(String)
}

protocol WebPreviewDirectCSSWriting: Sendable {
  /// Applies one declaration edit. When `embeddedStyleBlockIndex` is set,
  /// `filePath` is an HTML file and the edit targets the CSS inside its N-th
  /// inline `<style>` block (blocks are re-located at write time so earlier
  /// writes cannot invalidate offsets).
  func write(
    edit: CSSDeclarationEdit,
    filePath: String,
    embeddedStyleBlockIndex: Int?,
    expectedSHA256: String,
    projectPath: String
  ) async -> DirectWriteOutcome
}

actor WebPreviewDirectCSSWriteCoordinator: WebPreviewDirectCSSWriting {
  private let fileService: any ProjectFileServiceProtocol
  private let cssEditor: any CSSSourceEditing

  init(
    fileService: any ProjectFileServiceProtocol = ProjectFileService.shared,
    cssEditor: any CSSSourceEditing = CSSSourceEditor()
  ) {
    self.fileService = fileService
    self.cssEditor = cssEditor
  }

  func write(
    edit: CSSDeclarationEdit,
    filePath: String,
    embeddedStyleBlockIndex: Int?,
    expectedSHA256: String,
    projectPath: String
  ) async -> DirectWriteOutcome {
    let content: String
    do {
      content = try await fileService.readFile(at: filePath, projectPath: projectPath)
    } catch {
      return .editFailed("Could not read \(filePath): \(error.localizedDescription)")
    }

    guard StylesheetSourceMapper.sha256(of: content) == expectedSHA256 else {
      return .baselineDrift
    }

    let edited: String
    if let blockIndex = embeddedStyleBlockIndex {
      guard let block = HTMLStylesheetScanner.inlineBlockContent(ordinal: blockIndex, in: content) else {
        return .editFailed("Inline <style> block \(blockIndex) not found in \(filePath)")
      }

      let editedBlock: String
      do {
        editedBlock = try cssEditor.applyingDeclarationEdit(edit, to: block.content)
      } catch {
        return .editFailed("Edit rejected: \(error)")
      }

      guard editedBlock != block.content else {
        return .written(newSHA256: expectedSHA256)
      }

      var bytes = Array(content.utf8)
      bytes.replaceSubrange(block.contentRange, with: Array(editedBlock.utf8))
      guard let spliced = String(bytes: bytes, encoding: .utf8) else {
        return .editFailed("Spliced HTML is not valid UTF-8")
      }
      edited = spliced
    } else {
      do {
        edited = try cssEditor.applyingDeclarationEdit(edit, to: content)
      } catch {
        return .editFailed("Edit rejected: \(error)")
      }

      guard edited != content else {
        return .written(newSHA256: expectedSHA256)
      }
    }

    do {
      try await fileService.writeFile(at: filePath, content: edited, projectPath: projectPath)
    } catch {
      return .editFailed("Write failed: \(error.localizedDescription)")
    }

    return .written(newSHA256: StylesheetSourceMapper.sha256(of: edited))
  }
}
