//
//  PreviewScannerProtocol.swift
//  SwiftUIPreviewKit
//
//  Protocol for scanning Swift source files for #Preview declarations.
//

import Foundation

public protocol PreviewScannerProtocol: Sendable {
  /// Scans all .swift files under `projectPath` for #Preview blocks.
  func scanForPreviews(in projectPath: String, moduleName: String?) async -> [PreviewDeclaration]

  /// Scans a single file for #Preview blocks.
  func scanFile(at filePath: String, moduleName: String?) -> [PreviewDeclaration]
}
