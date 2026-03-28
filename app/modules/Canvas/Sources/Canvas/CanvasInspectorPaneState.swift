import Foundation

public struct CanvasInspectorPaneState: Codable, Equatable, Sendable {
  public let title: String
  public let subtitle: String?
  public let selector: String?
  public let statusText: String
  public let messageText: String?
  public let messageTone: CanvasInspectorPaneMessageTone?
  public let sections: [CanvasInspectorPaneSection]

  public init(
    title: String,
    subtitle: String?,
    selector: String?,
    statusText: String,
    messageText: String?,
    messageTone: CanvasInspectorPaneMessageTone?,
    sections: [CanvasInspectorPaneSection]
  ) {
    self.title = title
    self.subtitle = subtitle
    self.selector = selector
    self.statusText = statusText
    self.messageText = messageText
    self.messageTone = messageTone
    self.sections = sections
  }
}
