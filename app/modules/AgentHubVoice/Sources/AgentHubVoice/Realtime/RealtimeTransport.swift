import Foundation
import SwiftOpenAI

public enum RealtimeTransportCommand: Equatable, Sendable {
  case inputAudio(String)
  case functionOutput(callID: String, output: String)
  case responseCreate
  case backgroundUpdate(String)
  case truncateAudio(itemID: String, audioEndMS: Int)
}

@RealtimeActor
public protocol RealtimeTransport: AnyObject, Sendable {
  nonisolated var events: AsyncStream<OpenAIRealtimeMessage> { get }
  func send(_ command: RealtimeTransportCommand) async
  func disconnect()
}

@RealtimeActor
public final class LiveRealtimeTransport: RealtimeTransport {
  public nonisolated let events: AsyncStream<OpenAIRealtimeMessage>
  private let session: OpenAIRealtimeSession

  public init(session: OpenAIRealtimeSession) {
    self.session = session
    events = session.receiver
  }

  public func send(_ command: RealtimeTransportCommand) async {
    switch command {
    case .inputAudio(let audio):
      await session.sendMessage(
        OpenAIRealtimeInputAudioBufferAppend(audio: audio)
      )
    case .functionOutput(let callID, let output):
      await session.sendMessage(
        OpenAIRealtimeFunctionCallOutput(callID: callID, output: output)
      )
    case .responseCreate:
      await session.sendMessage(OpenAIRealtimeResponseCreate())
    case .backgroundUpdate(let update):
      await session.sendMessage(
        OpenAIRealtimeConversationItemCreate(
          item: .init(role: "system", text: "[session_update] \(update)")
        )
      )
    case .truncateAudio(let itemID, let audioEndMS):
      await session.sendMessage(
        OpenAIRealtimeConversationItemTruncate(
          itemID: itemID,
          audioEndMS: audioEndMS
        )
      )
    }
  }

  public func disconnect() {
    session.disconnect()
  }
}
