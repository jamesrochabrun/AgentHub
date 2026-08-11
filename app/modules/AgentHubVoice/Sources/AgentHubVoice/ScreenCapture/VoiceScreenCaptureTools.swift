//
//  VoiceScreenCaptureTools.swift
//  AgentHubVoice
//
//  Ready-made realtime tools for screen capture. A host app appends these to
//  its tool catalog to give the voice agent multi-display screenshots.
//

import Foundation

@MainActor
public enum VoiceScreenCaptureTools {
  public static func make(
    capture: any VoiceScreenCapturing,
    isEnabled: @escaping @MainActor @Sendable () -> Bool
  ) -> [VoiceTool] {
    [
      listDisplaysTool(capture: capture, isEnabled: isEnabled),
      captureScreenTool(capture: capture, isEnabled: isEnabled),
    ]
  }

  private static func listDisplaysTool(
    capture: any VoiceScreenCapturing,
    isEnabled: @escaping @MainActor @Sendable () -> Bool
  ) -> VoiceTool {
    VoiceTool(
      name: "list_displays",
      description: """
        List connected displays with their 1-based index, name, and size in
        points. Call this before capture_screen when the user refers to a
        specific monitor, such as an external display.
        """,
      parameters: [
        "type": "object",
        "properties": .object([:]),
        "additionalProperties": false,
      ]
    ) { _ in
      guard isEnabled() else { return disabledJSON }
      do {
        return encode(
          DisplayListResult(status: "ok", displays: try await capture.listDisplays())
        )
      } catch {
        return encode(
          FailureResult(status: "error", message: error.localizedDescription)
        )
      }
    }
  }

  private static func captureScreenTool(
    capture: any VoiceScreenCapturing,
    isEnabled: @escaping @MainActor @Sendable () -> Bool
  ) -> VoiceTool {
    VoiceTool(
      name: "capture_screen",
      description: """
        Capture a screenshot of a display, or a region of it, and save it as a
        PNG. Returns the file path — include that path in a prompt so an agent
        can open the image. Omit display_index for the main display; use
        list_displays to target an external monitor. The optional region is in
        points from the display's top-left corner.
        """,
      parameters: [
        "type": "object",
        "properties": .object([
          "display_index": [
            "type": "integer",
            "description": "1-based display index from list_displays. Defaults to the main display.",
          ],
          "region": .object([
            "type": "object",
            "description": "Optional area to capture, in points from the display's top-left corner.",
            "properties": .object([
              "x": ["type": "number"],
              "y": ["type": "number"],
              "width": ["type": "number"],
              "height": ["type": "number"],
            ]),
            "required": .array(["x", "y", "width", "height"]),
            "additionalProperties": false,
          ]),
        ]),
        "additionalProperties": false,
      ]
    ) { data in
      guard isEnabled() else { return disabledJSON }
      let arguments = decode(CaptureArguments.self, from: data)
      do {
        let result = try await capture.capture(
          displayIndex: arguments?.displayIndex,
          region: arguments?.region.map {
            VoiceCaptureRegion(
              x: $0.x,
              y: $0.y,
              width: $0.width,
              height: $0.height
            )
          }
        )
        return encode(CaptureResult(status: "captured", capture: result))
      } catch {
        return encode(
          FailureResult(status: "error", message: error.localizedDescription)
        )
      }
    }
  }

  // MARK: - Payloads

  private struct CaptureArguments: Decodable {
    struct Region: Decodable {
      let x: Double
      let y: Double
      let width: Double
      let height: Double
    }

    let displayIndex: Int?
    let region: Region?
  }

  private struct DisplayListResult: Encodable {
    let status: String
    let displays: [VoiceCaptureDisplay]
  }

  private struct CaptureResult: Encodable {
    let status: String
    let capture: VoiceScreenCaptureResult
  }

  private struct FailureResult: Encodable {
    let status: String
    let message: String
  }

  private static let disabledJSON =
    #"{"status":"disabled","message":"Screen capture is turned off in settings."}"#

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(type, from: data)
  }

  private static func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else {
      return #"{"status":"error","message":"Could not encode the tool result."}"#
    }
    return String(decoding: data, as: UTF8.self)
  }
}
