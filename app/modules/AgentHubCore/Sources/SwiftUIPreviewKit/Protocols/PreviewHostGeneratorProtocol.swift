//
//  PreviewHostGeneratorProtocol.swift
//  SwiftUIPreviewKit
//
//  Protocol for generating a minimal Xcode project that renders a single preview.
//

import Foundation

public protocol PreviewHostGeneratorProtocol: Sendable {
  /// Generates a minimal host .xcodeproj that imports the user's module and renders
  /// the given preview body expression.
  func generateHostProject(
    for preview: PreviewDeclaration,
    userDerivedDataPath: String,
    scheme: String
  ) async throws -> GeneratedPreviewHost
}
