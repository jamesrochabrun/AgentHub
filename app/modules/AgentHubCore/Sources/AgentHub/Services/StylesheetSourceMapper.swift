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
  case proven(filePath: String, contentSHA256: String)
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

      return .proven(filePath: candidate, contentSHA256: Self.sha256(of: content))
    }

    return .unproven(reason: "No candidate file matched the runtime rule")
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
