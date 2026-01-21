//
//  PendingChangesPreviewService.swift
//  AgentHub
//
//  Created by Assistant on 1/21/26.
//

import Foundation

// MARK: - PendingChangesPreviewService

/// Service for generating preview diffs of pending code changes before they are applied
public struct PendingChangesPreviewService {

  // MARK: - Types

  /// Result of generating a pending changes preview
  public struct PreviewResult: Sendable {
    public let filePath: String
    public let fileName: String
    public let currentContent: String
    public let previewContent: String
    public let toolType: CodeChangeInput.ToolType
    public let isNewFile: Bool

    public init(
      filePath: String,
      fileName: String,
      currentContent: String,
      previewContent: String,
      toolType: CodeChangeInput.ToolType,
      isNewFile: Bool
    ) {
      self.filePath = filePath
      self.fileName = fileName
      self.currentContent = currentContent
      self.previewContent = previewContent
      self.toolType = toolType
      self.isNewFile = isNewFile
    }
  }

  /// Errors that can occur during preview generation
  public enum PreviewError: LocalizedError {
    case fileNotFound(path: String)
    case oldStringNotFound(oldString: String, filePath: String)
    case invalidToolInput
    case fileReadError(underlying: Error)

    public var errorDescription: String? {
      switch self {
      case .fileNotFound(let path):
        return "File not found: \(path)"
      case .oldStringNotFound(let oldString, let filePath):
        let preview = String(oldString.prefix(50))
        let suffix = oldString.count > 50 ? "..." : ""
        return "Could not find '\(preview)\(suffix)' in \(URL(fileURLWithPath: filePath).lastPathComponent)"
      case .invalidToolInput:
        return "Invalid tool input parameters"
      case .fileReadError(let error):
        return "Failed to read file: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Public API

  /// Generates a preview of pending changes
  /// - Parameter codeChangeInput: The pending tool's input parameters
  /// - Returns: PreviewResult with current and preview content
  public static func generatePreview(
    for codeChangeInput: CodeChangeInput
  ) async throws -> PreviewResult {
    let filePath = codeChangeInput.filePath
    let fileName = URL(fileURLWithPath: filePath).lastPathComponent

    // Read current file content
    let currentContent: String
    let isNewFile: Bool

    if FileManager.default.fileExists(atPath: filePath) {
      do {
        currentContent = try String(contentsOfFile: filePath, encoding: .utf8)
        isNewFile = false
      } catch {
        throw PreviewError.fileReadError(underlying: error)
      }
    } else {
      // New file case - only valid for Write tool
      currentContent = ""
      isNewFile = true
    }

    // Generate preview content based on tool type
    let previewContent: String

    switch codeChangeInput.toolType {
    case .edit:
      previewContent = try applyEditPreview(
        currentContent: currentContent,
        oldString: codeChangeInput.oldString,
        newString: codeChangeInput.newString,
        replaceAll: codeChangeInput.replaceAll ?? false,
        filePath: filePath
      )

    case .write:
      // Write replaces entire file
      previewContent = codeChangeInput.newString ?? ""

    case .multiEdit:
      previewContent = try applyMultiEditPreview(
        currentContent: currentContent,
        edits: codeChangeInput.edits,
        filePath: filePath
      )
    }

    return PreviewResult(
      filePath: filePath,
      fileName: fileName,
      currentContent: currentContent,
      previewContent: previewContent,
      toolType: codeChangeInput.toolType,
      isNewFile: isNewFile
    )
  }

  // MARK: - Private Helpers

  private static func applyEditPreview(
    currentContent: String,
    oldString: String?,
    newString: String?,
    replaceAll: Bool,
    filePath: String
  ) throws -> String {
    guard let oldString = oldString,
          let newString = newString else {
      throw PreviewError.invalidToolInput
    }

    if replaceAll {
      let result = currentContent.replacingOccurrences(of: oldString, with: newString)
      // Check if any replacement was made
      if result == currentContent && !currentContent.contains(oldString) {
        throw PreviewError.oldStringNotFound(oldString: oldString, filePath: filePath)
      }
      return result
    } else {
      // Single replacement
      guard let range = currentContent.range(of: oldString) else {
        throw PreviewError.oldStringNotFound(oldString: oldString, filePath: filePath)
      }
      return currentContent.replacingCharacters(in: range, with: newString)
    }
  }

  private static func applyMultiEditPreview(
    currentContent: String,
    edits: [[String: String]]?,
    filePath: String
  ) throws -> String {
    guard let edits = edits, !edits.isEmpty else {
      throw PreviewError.invalidToolInput
    }

    var result = currentContent

    for edit in edits {
      guard let oldString = edit["old_string"],
            let newString = edit["new_string"] else {
        continue
      }

      let replaceAll = edit["replace_all"] == "true"

      if replaceAll {
        result = result.replacingOccurrences(of: oldString, with: newString)
      } else if let range = result.range(of: oldString) {
        result = result.replacingCharacters(in: range, with: newString)
      }
      // Note: We don't throw if old_string not found in MultiEdit
      // since some edits may be sequential and depend on previous edits
    }

    return result
  }
}
