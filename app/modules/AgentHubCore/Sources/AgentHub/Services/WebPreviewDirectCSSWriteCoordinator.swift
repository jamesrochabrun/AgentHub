//
//  WebPreviewDirectCSSWriteCoordinator.swift
//  AgentHub
//
//  Applies a proven Tier-1 CSS declaration edit to disk. Re-reads the file and
//  verifies the SHA-256 baseline immediately before writing so a concurrent
//  agent edit is never clobbered; the splice itself enforces the
//  CSSSourceEditor post-conditions before any bytes are written.
//
//  Before splicing, the edit is planned against the freshly-read source so the
//  code's idioms (design tokens, clamp(), units, color notation) survive; an
//  edit whose declared value already matches skips the write entirely.
//

import Foundation

enum DirectWriteOutcome: Equatable, Sendable {
  case written(newSHA256: String)
  /// The write landed, but it flattened a shared design token into a
  /// literal — carries what the caller needs to offer promoting the edit to
  /// a token-wide update instead.
  case writtenWithTokenDetachment(newSHA256: String, detachment: CSSTokenDetachment)
  case baselineDrift
  case editFailed(String)

  /// The post-write SHA for either success case.
  var writtenSHA256: String? {
    switch self {
    case .written(let sha), .writtenWithTokenDetachment(let sha, _):
      return sha
    case .baselineDrift, .editFailed:
      return nil
    }
  }
}

protocol WebPreviewDirectCSSWriting: Sendable {
  /// Applies one declaration edit. When `embeddedStyleBlockIndex` is set,
  /// `filePath` is an HTML file and the edit targets the CSS inside its N-th
  /// inline `<style>` block (blocks are re-located at write time so earlier
  /// writes cannot invalidate offsets). The edit is planned against the
  /// freshly-read source first so declared idioms (tokens, clamp(), units,
  /// color notation) are preserved; `environment` supplies the page's unit
  /// conversion context.
  func write(
    edit: CSSDeclarationEdit,
    filePath: String,
    embeddedStyleBlockIndex: Int?,
    expectedSHA256: String,
    environment: WebPreviewPageEnvironment,
    projectPath: String
  ) async -> DirectWriteOutcome
}

actor WebPreviewDirectCSSWriteCoordinator: WebPreviewDirectCSSWriting {
  private let fileService: any ProjectFileServiceProtocol
  private let cssEditor: any CSSSourceEditing
  private let planner: any CSSDeclarationEditPlanning

  init(
    fileService: any ProjectFileServiceProtocol = ProjectFileService.shared,
    cssEditor: any CSSSourceEditing = CSSSourceEditor(),
    planner: any CSSDeclarationEditPlanning = CSSDeclarationEditPlanner()
  ) {
    self.fileService = fileService
    self.cssEditor = cssEditor
    self.planner = planner
  }

  func write(
    edit: CSSDeclarationEdit,
    filePath: String,
    embeddedStyleBlockIndex: Int?,
    expectedSHA256: String,
    environment: WebPreviewPageEnvironment,
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

    let detachment: CSSTokenDetachment?
    let edited: String
    if let blockIndex = embeddedStyleBlockIndex {
      guard let block = HTMLStylesheetScanner.inlineBlockContent(ordinal: blockIndex, in: content) else {
        return .editFailed("Inline <style> block \(blockIndex) not found in \(filePath)")
      }

      guard let plan = await plan(
        edit,
        for: block.content,
        siblingSource: .embeddedBlock(html: content, ordinal: blockIndex, htmlPath: filePath),
        environment: environment,
        projectPath: projectPath
      ), let plannedEdit = plan.edit else {
        return .written(newSHA256: expectedSHA256)
      }
      detachment = plan.tokenDetachment

      let editedBlock: String
      do {
        editedBlock = try cssEditor.applyingDeclarationEdit(plannedEdit, to: block.content)
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
      guard let plan = await plan(
        edit,
        for: content,
        siblingSource: .cssFile(path: filePath),
        environment: environment,
        projectPath: projectPath
      ), let plannedEdit = plan.edit else {
        return .written(newSHA256: expectedSHA256)
      }
      detachment = plan.tokenDetachment

      do {
        edited = try cssEditor.applyingDeclarationEdit(plannedEdit, to: content)
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

    let newSHA256 = StylesheetSourceMapper.sha256(of: edited)
    if let detachment {
      return .writtenWithTokenDetachment(newSHA256: newSHA256, detachment: detachment)
    }
    return .written(newSHA256: newSHA256)
  }

  // MARK: - Planning

  /// Where the edited CSS lives, so sibling stylesheets can be gathered for
  /// cross-file token resolution.
  private enum EditedSource {
    case cssFile(path: String)
    case embeddedBlock(html: String, ordinal: Int, htmlPath: String)
  }

  /// Runs the deterministic planner against the source the edit targets.
  /// Nil means the declaration already holds the desired value — skip the
  /// write. If the source cannot be parsed the original edit is used and the
  /// splice's own post-conditions remain the safety net.
  private func plan(
    _ edit: CSSDeclarationEdit,
    for source: String,
    siblingSource: EditedSource,
    environment: WebPreviewPageEnvironment,
    projectPath: String
  ) async -> CSSDeclarationEditPlan? {
    guard let document = try? cssEditor.parse(source) else {
      return CSSDeclarationEditPlan(edit: edit, strategy: .passthrough)
    }

    // Sibling stylesheets only influence token planning; skip the project
    // scan when the edited declaration holds no `var()` reference.
    var siblings: [CSSSourceDocument] = []
    if editTargetsVarReference(edit, in: document) {
      siblings = await siblingDocuments(for: siblingSource, projectPath: projectPath)
    }

    let plan = planner.plan(edit, in: document, siblings: siblings, environment: environment)
    if case .noChange = plan.strategy { return nil }
    if plan.edit == nil {
      return CSSDeclarationEditPlan(
        edit: edit,
        strategy: plan.strategy,
        tokenDetachment: plan.tokenDetachment
      )
    }
    return plan
  }

  private func editTargetsVarReference(_ edit: CSSDeclarationEdit, in document: CSSSourceDocument) -> Bool {
    guard let rule = document.rule(at: edit.ruleIndexPath),
          let declaration = rule.declarations.last(where: {
            $0.name == CSSSourceEditor.canonicalPropertyName(edit.property)
          }) else {
      return false
    }
    return CSSDeclarationEditPlanner.pureVarReference(declaration.valueText) != nil
  }

  /// Parses every other stylesheet the page could reach: the project's CSS
  /// files (bounded) and, when editing an inline <style> block, the sibling
  /// blocks of the same HTML file.
  private func siblingDocuments(
    for source: EditedSource,
    projectPath: String
  ) async -> [CSSSourceDocument] {
    var documents: [CSSSourceDocument] = []

    let cssPaths = await fileService.listTextFiles(in: projectPath, extensions: ["css"])
    let excludedPath: String? = {
      if case .cssFile(let path) = source { return path }
      return nil
    }()
    for path in cssPaths.prefix(Self.maxSiblingStylesheets) where path != excludedPath {
      guard let css = try? await fileService.readFile(at: path, projectPath: projectPath),
            let document = try? cssEditor.parse(css) else {
        continue
      }
      documents.append(document)
    }

    if case .embeddedBlock(let html, let ordinal, _) = source {
      for blockSource in HTMLStylesheetScanner.stylesheetSources(in: html) {
        guard case .inlineBlock(let contentRange, let blockOrdinal, _) = blockSource,
              blockOrdinal != ordinal else {
          continue
        }
        let bytes = Array(html.utf8)
        guard contentRange.lowerBound >= 0, contentRange.upperBound <= bytes.count,
              let css = String(bytes: bytes[contentRange], encoding: .utf8),
              let document = try? cssEditor.parse(css) else {
          continue
        }
        documents.append(document)
      }
    }

    return documents
  }

  private static let maxSiblingStylesheets = 64
}
