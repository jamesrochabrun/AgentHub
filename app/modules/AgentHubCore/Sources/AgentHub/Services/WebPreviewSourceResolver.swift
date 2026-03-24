//
//  WebPreviewSourceResolver.swift
//  AgentHub
//
//  Heuristic source resolver for the web preview inspector rail.
//

import Canvas
import Foundation

protocol WebPreviewSourceResolverProtocol: Sendable {
  func resolveSource(
    for element: ElementInspectorData,
    projectPath: String,
    previewFilePath: String?,
    recentActivities: [ActivityEntry]
  ) async -> WebPreviewSourceResolution
}

actor WebPreviewSourceResolver: WebPreviewSourceResolverProtocol {
  private struct CandidateScore: Sendable {
    let path: String
    let score: Int
    let matchedRanges: [WebPreviewSourceMatchRange]
    let matchedSelector: String?
    let supportsStyleEditing: Bool
  }

  private let fileService: any ProjectFileServiceProtocol

  private static let supportedExtensions: Set<String> = [
    "html", "htm", "css", "scss", "js", "ts", "jsx", "tsx", "vue", "svelte",
  ]

  private static let styleExtensions: Set<String> = ["css", "scss"]

  init(fileService: any ProjectFileServiceProtocol = ProjectFileService.shared) {
    self.fileService = fileService
  }

  func resolveSource(
    for element: ElementInspectorData,
    projectPath: String,
    previewFilePath: String?,
    recentActivities: [ActivityEntry]
  ) async -> WebPreviewSourceResolution {
    let normalizedProjectPath = Self.normalize(path: projectPath)
    let normalizedPreviewFilePath = previewFilePath.map(Self.normalize(path:))
    let recentFiles = Self.recentWebFiles(from: recentActivities, projectPath: normalizedProjectPath)
    let seedPaths = Self.seedPaths(
      previewFilePath: normalizedPreviewFilePath,
      recentFiles: recentFiles,
      projectPath: normalizedProjectPath
    )

    var scoredCandidates = await scoreCandidates(
      paths: seedPaths,
      element: element,
      projectPath: normalizedProjectPath,
      previewFilePath: normalizedPreviewFilePath,
      recentFiles: Set(recentFiles)
    )

    let currentTopScore = scoredCandidates.map(\.score).max() ?? 0
    let hasStyleCandidate = scoredCandidates.contains { $0.supportsStyleEditing }
    if currentTopScore < 150 || !hasStyleCandidate {
      let allFiles = await fileService.listTextFiles(
        in: normalizedProjectPath,
        extensions: Self.supportedExtensions
      )
      let additionalPaths = allFiles.filter { !Set(seedPaths).contains($0) }
      let additionalScores = await scoreCandidates(
        paths: Array(additionalPaths.prefix(300)),
        element: element,
        projectPath: normalizedProjectPath,
        previewFilePath: normalizedPreviewFilePath,
        recentFiles: Set(recentFiles)
      )
      scoredCandidates.append(contentsOf: additionalScores)
    }

    let sorted = scoredCandidates.sorted { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      return lhs.path < rhs.path
    }

    let styleSorted = sorted.filter(\.supportsStyleEditing)
    let preferredBest = styleSorted.first ?? sorted.first

    let candidatePaths = Array(sorted.prefix(5).map(\.path))

    guard let best = preferredBest, best.score > 0 else {
      return WebPreviewSourceResolution(
        primaryFilePath: normalizedPreviewFilePath,
        candidateFilePaths: candidatePaths,
        confidence: .low,
        matchedRanges: [:],
        editableCapabilities: [.code],
        matchedSelector: nil,
        matchedStylesheetPath: nil,
        allowsInlineStyleEditing: false,
        matchedText: nil
      )
    }

    let nextBest: CandidateScore?
    if Self.styleExtensions.contains(URL(fileURLWithPath: best.path).pathExtension.lowercased()) {
      nextBest = styleSorted.drop(while: { $0.path == best.path }).first
    } else {
      nextBest = sorted.drop(while: { $0.path == best.path }).first
    }

    let confidence = Self.confidence(for: best, nextBest: nextBest)
    let matchedStylesheetPath =
      Self.styleExtensions.contains(URL(fileURLWithPath: best.path).pathExtension.lowercased())
      && best.supportsStyleEditing ? best.path : nil
    let allowsInlineStyleEditing = confidence > .low && best.supportsStyleEditing

    var capabilities: Set<WebPreviewEditableCapability> = [.code]
    if allowsInlineStyleEditing {
      for property in WebPreviewStyleProperty.allCases {
        capabilities.insert(property.capability)
      }
    }

    return WebPreviewSourceResolution(
      primaryFilePath: best.path,
      candidateFilePaths: LinkedHashSet(elements: [best.path] + candidatePaths).elements,
      confidence: confidence,
      matchedRanges: [best.path: best.matchedRanges],
      editableCapabilities: capabilities,
      matchedSelector: best.matchedSelector,
      matchedStylesheetPath: matchedStylesheetPath,
      allowsInlineStyleEditing: allowsInlineStyleEditing,
      matchedText: element.textContent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    )
  }

  // MARK: - Candidate Scoring

  private func scoreCandidates(
    paths: [String],
    element: ElementInspectorData,
    projectPath: String,
    previewFilePath: String?,
    recentFiles: Set<String>
  ) async -> [CandidateScore] {
    let tokens = Self.makeTokens(from: element)
    var results: [CandidateScore] = []

    for path in LinkedHashSet(elements: paths).elements {
      let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
      guard Self.supportedExtensions.contains(ext) else { continue }

      guard let content = try? await fileService.readFile(at: path, projectPath: projectPath) else {
        continue
      }

      var score = 0
      var matchedRanges: [WebPreviewSourceMatchRange] = []
      var matchedSelector: String?

      if path == previewFilePath {
        score += 80
      }
      if recentFiles.contains(path) {
        score += 55
      }
      if Self.styleExtensions.contains(ext), URL(fileURLWithPath: path).lastPathComponent.lowercased().contains("style") {
        score += 10
      }

      if let fullSelector = tokens.fullSelector,
         let range = Self.firstLiteralRange(of: fullSelector, in: content) {
        score += 140
        matchedSelector = fullSelector
        matchedRanges.append(range)
      }

      if matchedSelector == nil {
        for selector in tokens.selectorCandidates {
          if let range = Self.firstLiteralRange(of: selector, in: content) {
            score += selector.hasPrefix(".") || selector.hasPrefix("#") ? 105 : 85
            matchedSelector = selector
            matchedRanges.append(range)
            break
          }
        }
      }

      let exactText = tokens.text
      if let exactText {
        let textMatches = Self.literalMatchRanges(of: exactText, in: content)
        if textMatches.count == 1 {
          score += 95
          matchedRanges.append(textMatches[0])
        } else if !textMatches.isEmpty {
          score += 70
          matchedRanges.append(textMatches[0])
        }
      }

      for token in tokens.plainTokens {
        if Self.firstLiteralRange(of: token, in: content) != nil {
          score += 16
        }
      }

      if tokens.tagName != nil, content.localizedCaseInsensitiveContains("<\(tokens.tagName ?? "")") {
        score += 10
      }

      let supportsStyleEditing = matchedSelector.map { selector in
        Self.cssBodyRange(for: [selector], in: content) != nil
      } ?? false

      if supportsStyleEditing {
        score += Self.styleExtensions.contains(ext) ? 90 : 65
      }

      results.append(CandidateScore(
        path: path,
        score: score,
        matchedRanges: matchedRanges,
        matchedSelector: matchedSelector,
        supportsStyleEditing: supportsStyleEditing
      ))
    }

    return results
  }

  // MARK: - Heuristics

  private static func confidence(for best: CandidateScore, nextBest: CandidateScore?) -> WebPreviewSourceResolutionConfidence {
    let gap = best.score - (nextBest?.score ?? 0)
    if best.score >= 190, gap >= 25 {
      return .high
    }
    if best.score >= 130, gap >= 25 {
      return .medium
    }
    return .low
  }

  private static func recentWebFiles(from activities: [ActivityEntry], projectPath: String) -> [String] {
    var files: [String] = []

    for activity in activities.reversed() {
      guard let path = activity.toolInput?.filePath else { continue }
      let normalizedPath = normalize(path: path)
      let ext = URL(fileURLWithPath: normalizedPath).pathExtension.lowercased()
      guard supportedExtensions.contains(ext),
            isPath(normalizedPath, inside: projectPath) else {
        continue
      }
      files.append(normalizedPath)
      if files.count == 12 {
        break
      }
    }

    return LinkedHashSet(elements: files).elements
  }

  private static func seedPaths(
    previewFilePath: String?,
    recentFiles: [String],
    projectPath: String
  ) -> [String] {
    var paths: [String] = []

    if let previewFilePath {
      paths.append(previewFilePath)
      paths.append(contentsOf: siblingStyleFiles(near: previewFilePath, projectPath: projectPath))
    }

    for recentFile in recentFiles {
      paths.append(recentFile)
      paths.append(contentsOf: siblingStyleFiles(near: recentFile, projectPath: projectPath))
    }

    return LinkedHashSet(elements: paths).elements
  }

  private static func siblingStyleFiles(near filePath: String, projectPath: String) -> [String] {
    let directoryURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return entries.compactMap { url in
      let ext = url.pathExtension.lowercased()
      guard styleExtensions.contains(ext) else { return nil }
      let normalizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
      guard isPath(normalizedPath, inside: projectPath) else { return nil }
      return normalizedPath
    }
  }

  private static func makeTokens(from element: ElementInspectorData) -> SourceTokens {
    let normalizedSelector = normalizeSelector(element.cssSelector)
    let selectorSegments = normalizedSelector
      .components(separatedBy: ">")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let classNames = element.className
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .filter { !$0.isEmpty }

    let selectorCandidates = LinkedHashSet(elements:
      (element.elementId.isEmpty ? [] : ["#\(element.elementId)"])
        + classNames.map { ".\($0)" }
        + selectorSegments.reversed()
    ).elements

    let plainTokens = LinkedHashSet(elements:
      classNames
        + (element.elementId.isEmpty ? [] : [element.elementId])
        + selectorSegments
    ).elements

    return SourceTokens(
      tagName: element.tagName.lowercased().nilIfEmpty,
      text: element.textContent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      fullSelector: normalizedSelector.nilIfEmpty,
      selectorCandidates: selectorCandidates,
      plainTokens: plainTokens
    )
  }

  private static func normalizeSelector(_ selector: String) -> String {
    var normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized = normalized.replacingOccurrences(
      of: #":nth-of-type\(\d+\)"#,
      with: "",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    normalized = normalized.replacingOccurrences(of: " > ", with: " > ")
    return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func literalMatchRanges(of needle: String, in haystack: String) -> [WebPreviewSourceMatchRange] {
    guard !needle.isEmpty else { return [] }

    var matches: [WebPreviewSourceMatchRange] = []
    var searchStart = haystack.startIndex

    while searchStart < haystack.endIndex,
          let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
      matches.append(Self.makeRange(range, in: haystack))
      searchStart = range.upperBound
    }

    return matches
  }

  private static func firstLiteralRange(of needle: String, in haystack: String) -> WebPreviewSourceMatchRange? {
    guard !needle.isEmpty,
          let range = haystack.range(of: needle) else {
      return nil
    }
    return makeRange(range, in: haystack)
  }

  private static func cssBodyRange(
    for selectorCandidates: [String],
    in content: String
  ) -> Range<String.Index>? {
    for selector in selectorCandidates where !selector.isEmpty {
      guard let selectorRange = content.range(of: selector),
            let braceStart = content[selectorRange.upperBound...].firstIndex(of: "{") else {
        continue
      }

      var depth = 1
      var cursor = content.index(after: braceStart)
      while cursor < content.endIndex {
        let character = content[cursor]
        if character == "{" {
          depth += 1
        } else if character == "}" {
          depth -= 1
          if depth == 0 {
            return content.index(after: braceStart)..<cursor
          }
        }
        cursor = content.index(after: cursor)
      }
    }

    return nil
  }

  private static func makeRange(_ range: Range<String.Index>, in string: String) -> WebPreviewSourceMatchRange {
    WebPreviewSourceMatchRange(
      location: range.lowerBound.utf16Offset(in: string),
      length: range.upperBound.utf16Offset(in: string) - range.lowerBound.utf16Offset(in: string)
    )
  }

  private static func normalize(path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func isPath(_ path: String, inside rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
  }
}

private struct SourceTokens: Sendable {
  let tagName: String?
  let text: String?
  let fullSelector: String?
  let selectorCandidates: [String]
  let plainTokens: [String]
}

private struct LinkedHashSet<Element: Hashable> {
  let elements: [Element]

  init(elements: [Element]) {
    var seen: Set<Element> = []
    self.elements = elements.filter { seen.insert($0).inserted }
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
