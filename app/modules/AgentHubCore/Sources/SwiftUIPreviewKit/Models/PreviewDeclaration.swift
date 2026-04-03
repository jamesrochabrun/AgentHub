//
//  PreviewDeclaration.swift
//  SwiftUIPreviewKit
//
//  Data model for a discovered #Preview block in a Swift source file.
//

import Foundation

public struct PreviewDeclaration: Identifiable, Sendable, Hashable {
  public let id: UUID
  public let name: String?
  public let filePath: String
  public let lineNumber: Int
  public let bodyExpression: String
  public let moduleName: String?

  public var displayName: String {
    name ?? "Preview (line \(lineNumber))"
  }

  public var fileName: String {
    (filePath as NSString).lastPathComponent
  }

  public init(
    id: UUID = UUID(),
    name: String?,
    filePath: String,
    lineNumber: Int,
    bodyExpression: String,
    moduleName: String?
  ) {
    self.id = id
    self.name = name
    self.filePath = filePath
    self.lineNumber = lineNumber
    self.bodyExpression = bodyExpression
    self.moduleName = moduleName
  }
}
