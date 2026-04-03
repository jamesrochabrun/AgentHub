//
//  PreviewScanner.swift
//  SwiftUIPreviewKit
//
//  Scans Swift source files for #Preview declarations using regex + brace-depth counting.
//

import Foundation

public actor PreviewScanner: PreviewScannerProtocol {

  public init() {}

  // MARK: - Skipped directories

  private static let skippedDirectories: Set<String> = [
    ".git", ".svn", ".build", "DerivedData", "node_modules",
    ".next", ".nuxt", "dist", "build", "coverage", ".cache", "Pods",
  ]

  // MARK: - PreviewScannerProtocol

  public func scanForPreviews(in projectPath: String, moduleName: String?) async -> [PreviewDeclaration] {
    let files = await Task.detached(priority: .utility) {
      Self.enumerateSwiftFiles(in: projectPath)
    }.value

    var results: [PreviewDeclaration] = []
    for file in files {
      let previews = scanFile(at: file, moduleName: moduleName)
      results.append(contentsOf: previews)
    }
    return results.sorted {
      if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
      return $0.lineNumber < $1.lineNumber
    }
  }

  public nonisolated func scanFile(at filePath: String, moduleName: String?) -> [PreviewDeclaration] {
    guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
      return []
    }
    return Self.extractPreviews(from: content, filePath: filePath, moduleName: moduleName)
  }

  // MARK: - File enumeration

  private static func enumerateSwiftFiles(in projectPath: String) -> [String] {
    let rootURL = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath()
    let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]

    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var files: [String] = []
    while let fileURL = enumerator.nextObject() as? URL {
      let values = try? fileURL.resourceValues(forKeys: resourceKeys)
      if values?.isDirectory == true {
        if skippedDirectories.contains(fileURL.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      if fileURL.pathExtension == "swift" {
        files.append(fileURL.path)
      }
    }
    return files
  }

  // MARK: - Preview extraction

  /// Extracts all #Preview declarations from a Swift source string.
  static func extractPreviews(
    from source: String,
    filePath: String,
    moduleName: String?
  ) -> [PreviewDeclaration] {
    let lines = source.components(separatedBy: "\n")
    var results: [PreviewDeclaration] = []
    var lineIndex = 0

    while lineIndex < lines.count {
      let line = lines[lineIndex]

      // Skip lines inside line comments
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("//") {
        lineIndex += 1
        continue
      }

      // Check for #Preview
      guard let previewRange = line.range(of: "#Preview") else {
        lineIndex += 1
        continue
      }

      // Make sure it's not inside a block comment by checking preceding content
      let beforePreview = String(source[source.startIndex..<lineStartIndex(for: lineIndex, in: source)])
      if isInsideBlockComment(beforePreview) {
        lineIndex += 1
        continue
      }

      // Extract name if present: #Preview("Name")
      let afterPreview = String(line[previewRange.upperBound...])
      let name = extractPreviewName(from: afterPreview)

      // Find the opening brace — might be on same line or next lines
      let searchStart = sourceOffset(for: lineIndex, in: source) + line.distance(from: line.startIndex, to: previewRange.upperBound)
      guard let (bodyStart, bodyEnd) = extractBracedBody(from: source, searchFrom: searchStart) else {
        lineIndex += 1
        continue
      }

      let bodyStartIdx = source.index(source.startIndex, offsetBy: bodyStart)
      let bodyEndIdx = source.index(source.startIndex, offsetBy: bodyEnd)
      let bodyExpression = String(source[bodyStartIdx..<bodyEndIdx]).trimmingCharacters(in: .whitespacesAndNewlines)

      results.append(PreviewDeclaration(
        name: name,
        filePath: filePath,
        lineNumber: lineIndex + 1,
        bodyExpression: bodyExpression,
        moduleName: moduleName
      ))

      // Advance past the closing brace
      lineIndex = lineNumber(forOffset: bodyEnd, in: source)
      lineIndex += 1
    }

    return results
  }

  // MARK: - Name extraction

  /// Extracts the name string from #Preview("Name") if present.
  static func extractPreviewName(from afterPreview: String) -> String? {
    let trimmed = afterPreview.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("(") else { return nil }

    // Find the quoted string inside parens
    guard let quoteStart = trimmed.firstIndex(of: "\"") else { return nil }
    let afterQuote = trimmed[trimmed.index(after: quoteStart)...]
    guard let quoteEnd = afterQuote.firstIndex(of: "\"") else { return nil }

    return String(afterQuote[afterQuote.startIndex..<quoteEnd])
  }

  // MARK: - Brace extraction

  /// Starting from `searchFrom` offset, finds the first `{` and extracts the
  /// balanced body, returning (bodyStart, bodyEnd) offsets (exclusive of braces).
  /// Handles nested braces, string literals, and comments.
  static func extractBracedBody(from source: String, searchFrom: Int) -> (Int, Int)? {
    let chars = Array(source.unicodeScalars)
    let count = chars.count
    var i = searchFrom

    // Find opening brace
    while i < count && chars[i] != "{" {
      i += 1
    }
    guard i < count else { return nil }

    let bodyStart = i + 1  // After the opening brace
    var depth = 1
    i = bodyStart

    while i < count && depth > 0 {
      let c = chars[i]

      // Skip line comments
      if c == "/" && i + 1 < count && chars[i + 1] == "/" {
        while i < count && chars[i] != "\n" {
          i += 1
        }
        continue
      }

      // Skip block comments
      if c == "/" && i + 1 < count && chars[i + 1] == "*" {
        i += 2
        while i + 1 < count && !(chars[i] == "*" && chars[i + 1] == "/") {
          i += 1
        }
        i += 2
        continue
      }

      // Skip string literals
      if c == "\"" {
        // Check for multi-line string """
        if i + 2 < count && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
          i += 3
          while i + 2 < count && !(chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\"") {
            i += 1
          }
          i += 3
          continue
        }
        // Single-line string
        i += 1
        while i < count && chars[i] != "\"" && chars[i] != "\n" {
          if chars[i] == "\\" { i += 1 }  // Skip escaped character
          i += 1
        }
        if i < count { i += 1 }  // Skip closing quote
        continue
      }

      if c == "{" {
        depth += 1
      } else if c == "}" {
        depth -= 1
      }
      i += 1
    }

    guard depth == 0 else { return nil }
    let bodyEnd = i - 1  // Before the closing brace
    return (bodyStart, bodyEnd)
  }

  // MARK: - Comment detection

  /// Checks if the end of `text` is inside an unclosed block comment.
  static func isInsideBlockComment(_ text: String) -> Bool {
    var depth = 0
    let chars = Array(text.unicodeScalars)
    var i = 0
    while i < chars.count {
      if chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
        depth += 1
        i += 2
      } else if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
        depth = max(0, depth - 1)
        i += 2
      } else {
        i += 1
      }
    }
    return depth > 0
  }

  // MARK: - Offset helpers

  /// Returns the character offset of the start of the given line (0-indexed).
  static func sourceOffset(for lineIndex: Int, in source: String) -> Int {
    var offset = 0
    var current = 0
    for char in source.unicodeScalars {
      if current == lineIndex { return offset }
      if char == "\n" { current += 1 }
      offset += 1
    }
    return offset
  }

  /// Returns the line start index (as a String.Index) for the given line.
  static func lineStartIndex(for lineIndex: Int, in source: String) -> String.Index {
    var current = 0
    var idx = source.startIndex
    while idx < source.endIndex && current < lineIndex {
      if source[idx] == "\n" { current += 1 }
      idx = source.index(after: idx)
    }
    return idx
  }

  /// Returns the 0-indexed line number for a given character offset.
  static func lineNumber(forOffset offset: Int, in source: String) -> Int {
    var lineNum = 0
    var current = 0
    for char in source.unicodeScalars {
      if current >= offset { return lineNum }
      if char == "\n" { lineNum += 1 }
      current += 1
    }
    return lineNum
  }
}
