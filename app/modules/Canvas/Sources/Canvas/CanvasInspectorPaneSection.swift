import Foundation

public struct CanvasInspectorPaneSection: Codable, Equatable, Sendable, Identifiable {
  public let title: String
  public let fields: [CanvasInspectorPaneField]

  public var id: String { title }

  public init(title: String, fields: [CanvasInspectorPaneField]) {
    self.title = title
    self.fields = fields
  }
}
