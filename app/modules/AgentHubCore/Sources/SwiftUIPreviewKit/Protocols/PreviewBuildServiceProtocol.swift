//
//  PreviewBuildServiceProtocol.swift
//  SwiftUIPreviewKit
//
//  Protocol for the full preview build pipeline: scan → generate → build → capture.
//

import Foundation

@MainActor
public protocol PreviewBuildServiceProtocol: AnyObject {
  var buildState: PreviewBuildState { get }
  var previews: [PreviewDeclaration] { get }
  var selectedPreview: PreviewDeclaration? { get }

  func scanPreviews(projectPath: String, moduleName: String?) async
  func buildPreview(_ preview: PreviewDeclaration, udid: String, projectPath: String) async
  func cancelBuild()
}
