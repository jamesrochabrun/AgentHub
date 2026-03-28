import Foundation

public struct CanvasInspectorPaneField: Codable, Equatable, Sendable, Identifiable {
  public let identifier: String
  public let label: String
  public let kind: CanvasInspectorPaneFieldKind
  public let value: String
  public let unit: String?
  public let isEditable: Bool

  public var id: String { identifier }

  public init(
    identifier: String,
    label: String,
    kind: CanvasInspectorPaneFieldKind,
    value: String,
    unit: String? = nil,
    isEditable: Bool
  ) {
    self.identifier = identifier
    self.label = label
    self.kind = kind
    self.value = value
    self.unit = unit
    self.isEditable = isEditable
  }
}
