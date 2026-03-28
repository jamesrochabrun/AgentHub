import Foundation

public struct CanvasInspectorChange: Equatable, Sendable {
  public let property: String
  public let value: String

  public init(property: String, value: String) {
    self.property = property
    self.value = value
  }
}
