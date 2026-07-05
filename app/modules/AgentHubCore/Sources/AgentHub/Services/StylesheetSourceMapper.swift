//
//  StylesheetSourceMapper.swift
//  AgentHub
//
//  Maps a runtime CSS rule locator to a project file and PROVES the mapping
//  by parsing the file and matching the rule at the same index path. Only a
//  proven mapping is eligible for a Tier-1 direct write.
//

import CryptoKit
import Foundation

enum WebPreviewStylesheetPreviewContext: Equatable, Sendable {
  case directFile(servedFilePath: String, projectPath: String)
  case devServer(baseURL: URL, projectPath: String)

  var projectPath: String {
    switch self {
    case .directFile(_, let projectPath), .devServer(_, let projectPath):
      return projectPath
    }
  }
}

enum StylesheetMappingResult: Equatable, Sendable {
  /// `embeddedStyleBlockIndex` is set when the rule lives in the N-th inline
  /// `<style>` block of an HTML file rather than a standalone stylesheet.
  case proven(filePath: String, contentSHA256: String, embeddedStyleBlockIndex: Int?)
  case unproven(reason: String)
}

protocol StylesheetSourceMapping: Sendable {
  func mapToProvenFile(
    ruleLocator: WebPreviewCSSRuleLocator,
    context: WebPreviewStylesheetPreviewContext
  ) async -> StylesheetMappingResult
}

actor StylesheetSourceMapper: StylesheetSourceMapping {
  private let fileService: any ProjectFileServiceProtocol
  private let cssEditor: any CSSSourceEditing

  init(
    fileService: any ProjectFileServiceProtocol = ProjectFileService.shared,
    cssEditor: any CSSSourceEditing = CSSSourceEditor()
  ) {
    self.fileService = fileService
    self.cssEditor = cssEditor
  }

  func mapToProvenFile(
    ruleLocator: WebPreviewCSSRuleLocator,
    context: WebPreviewStylesheetPreviewContext
  ) async -> StylesheetMappingResult {
    // Inline <style> blocks have no href. On a dev server that serves
    // project files verbatim, prove them by locating the same block ordinal
    // inside the served HTML document.
    if ruleLocator.stylesheetHref == nil,
       ruleLocator.ownerNodeAttributes["data-vite-dev-id"] == nil,
       case .devServer(let baseURL, let projectPath) = context {
      return await mapInlineBlock(ruleLocator, baseURL: baseURL, projectPath: projectPath)
    }

    let candidates = Self.candidatePaths(for: ruleLocator, context: context)
    guard !candidates.isEmpty else {
      return .unproven(reason: "No mappable source file for this stylesheet")
    }

    for candidate in candidates {
      guard Self.isPath(candidate, inside: context.projectPath) else { continue }
      guard let content = try? await fileService.readFile(at: candidate, projectPath: context.projectPath) else {
        continue
      }
      guard let document = try? cssEditor.parse(content) else {
        continue
      }
      guard let rule = document.rule(at: ruleLocator.ruleIndexPath),
            let fileSelector = rule.normalizedSelectorText,
            fileSelector == CSSSourceEditor.normalizeSelector(ruleLocator.selectorText) else {
        continue
      }

      return .proven(filePath: candidate, contentSHA256: Self.sha256(of: content), embeddedStyleBlockIndex: nil)
    }

    return .unproven(reason: "No candidate file matched the runtime rule")
  }

  /// Proves a rule that lives in an inline `<style>` block: the served HTML
  /// document must contain, at the same stylesheet index, an inline block
  /// whose parsed rule at the same index path carries the same selector.
  private func mapInlineBlock(
    _ ruleLocator: WebPreviewCSSRuleLocator,
    baseURL: URL,
    projectPath: String
  ) async -> StylesheetMappingResult {
    for candidate in Self.servedDocumentCandidates(baseURL: baseURL, projectPath: projectPath) {
      guard Self.isPath(candidate, inside: projectPath),
            let html = try? await fileService.readFile(at: candidate, projectPath: projectPath) else {
        continue
      }
      let sources = HTMLStylesheetScanner.stylesheetSources(in: html)
      guard ruleLocator.styleSheetIndex >= 0,
            ruleLocator.styleSheetIndex < sources.count,
            case .inlineBlock(_, let ordinal, _) = sources[ruleLocator.styleSheetIndex],
            let block = HTMLStylesheetScanner.inlineBlockContent(ordinal: ordinal, in: html) else {
        continue
      }
      guard let document = try? cssEditor.parse(block.content),
            let rule = document.rule(at: ruleLocator.ruleIndexPath),
            let fileSelector = rule.normalizedSelectorText,
            fileSelector == CSSSourceEditor.normalizeSelector(ruleLocator.selectorText) else {
        continue
      }
      return .proven(
        filePath: candidate,
        contentSHA256: Self.sha256(of: html),
        embeddedStyleBlockIndex: ordinal
      )
    }
    return .unproven(reason: "The inline <style> block couldn't be matched to a served project file")
  }

  /// Which project file the dev server most plausibly served for a URL
  /// path, in deterministic priority order.
  static func servedDocumentCandidates(baseURL: URL, projectPath: String) -> [String] {
    var urlPath = baseURL.path
    if urlPath.isEmpty { urlPath = "/" }

    var paths: [String] = []
    if urlPath.hasSuffix("/") {
      paths.append(normalize(path: projectPath + urlPath + "index.html"))
    } else {
      paths.append(normalize(path: projectPath + urlPath))
      paths.append(normalize(path: projectPath + urlPath + "/index.html"))
      if !URL(fileURLWithPath: urlPath).lastPathComponent.contains(".") {
        paths.append(normalize(path: projectPath + urlPath + ".html"))
      }
    }

    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  static func sha256(of content: String) -> String {
    SHA256.hash(data: Data(content.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  // MARK: - Candidates

  static func candidatePaths(
    for ruleLocator: WebPreviewCSSRuleLocator,
    context: WebPreviewStylesheetPreviewContext
  ) -> [String] {
    var candidates: [String] = []

    // Vite dev mode tags injected style elements with the absolute source path.
    if let viteDevID = ruleLocator.ownerNodeAttributes["data-vite-dev-id"] {
      let withoutQuery = viteDevID.split(separator: "?", maxSplits: 1).first.map(String.init) ?? viteDevID
      if withoutQuery.hasPrefix("/") {
        candidates.append(normalize(path: withoutQuery))
      }
    }

    if let href = ruleLocator.stylesheetHref, let hrefURL = URL(string: href) {
      switch context {
      case .directFile(_, let projectPath):
        if hrefURL.isFileURL {
          let path = normalize(path: hrefURL.path)
          if isPath(path, inside: projectPath) {
            candidates.append(path)
          }
        }

      case .devServer(let baseURL, let projectPath):
        if hrefURL.isFileURL {
          candidates.append(normalize(path: hrefURL.path))
        } else if hrefURL.host == baseURL.host, hrefURL.port == baseURL.port {
          let urlPath = hrefURL.path
          if !urlPath.isEmpty, urlPath != "/" {
            candidates.append(normalize(path: projectPath + urlPath))
            candidates.append(normalize(path: projectPath + "/public" + urlPath))
          }
        }
      }
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }

  private static func normalize(path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func isPath(_ path: String, inside rootPath: String) -> Bool {
    let normalizedRoot = normalize(path: rootPath)
    return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
  }
}
