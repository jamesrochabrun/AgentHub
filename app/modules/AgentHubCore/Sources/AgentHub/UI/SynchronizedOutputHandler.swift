//
//  SynchronizedOutputHandler.swift
//  AgentHub
//
//  Handles DEC Private Mode 2026 (Synchronized Output) sequences to batch
//  terminal rendering and improve visual smoothness during Claude Code operations.
//
//  Also parses JSON lines from --output-format stream-json output for real-time
//  streaming to ConversationView.
//

import Foundation
import os

// MARK: - StreamingMessage

/// A parsed message from Claude CLI's stream-json output format.
/// Matches the JSON structure: {"type":"assistant","message":{"content":[...]}}
public struct StreamingMessage: Sendable {
  public enum MessageType: String, Sendable {
    case user
    case assistant
    case result
    case system
  }

  public let type: MessageType
  public let timestamp: Date
  public let textContent: String?
  public let toolUse: ToolUseInfo?
  public let toolResult: ToolResultInfo?

  public struct ToolUseInfo: Sendable {
    public let id: String
    public let name: String
    public let input: String?
  }

  public struct ToolResultInfo: Sendable {
    public let toolUseId: String
    public let success: Bool
  }
}

/// Handles DEC Private Mode 2026 (Synchronized Output) sequences.
///
/// When sync mode is enabled (DECSET 2026), terminal output is buffered.
/// When sync mode is disabled (DECRST 2026), buffered content is flushed
/// all at once, preventing visual flickering during rapid updates.
///
/// Also parses JSON lines from stream-json output mode and invokes callbacks
/// for real-time ConversationView updates.
///
/// Reference: https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036
public final class SynchronizedOutputHandler {

  // MARK: - Logging

  #if DEBUG
  private static let logger = Logger(subsystem: "com.anthropic.AgentHub", category: "SyncOutput")
  #endif

  // MARK: - DEC Mode 2026 Sequence Constants

  /// ESC [ ? 2026 h - Enable synchronized output (DECSET)
  private static let decsetSequence: [UInt8] = [0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x68]

  /// ESC [ ? 2026 l - Disable synchronized output (DECRST)
  private static let decrstSequence: [UInt8] = [0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x6C]

  /// Minimum sequence prefix to detect potential match (ESC [ ?)
  private static let sequencePrefix: [UInt8] = [0x1B, 0x5B, 0x3F]

  // MARK: - OSC Sequence Constants (filtered to suppress SwiftTerm warnings)

  /// ESC ] - OSC sequence start
  private static let oscStart: [UInt8] = [0x1B, 0x5D]

  /// BEL (0x07) - OSC terminator
  private static let bel: UInt8 = 0x07

  /// ESC \ - String terminator (ST)
  private static let stringTerminator: [UInt8] = [0x1B, 0x5C]

  // MARK: - State

  /// Whether synchronized output mode is currently enabled.
  public private(set) var isSyncEnabled: Bool = false

  /// Buffer for content received while sync mode is enabled.
  private var buffer: [UInt8] = []

  /// Partial sequence bytes from a previous chunk (for sequences split across chunks).
  private var partialSequence: [UInt8] = []

  /// Buffer for incomplete JSON lines (data that doesn't end with newline).
  private var jsonLineBuffer: String = ""

  /// Tracks if we're inside an OSC sequence that should be filtered (e.g., OSC 9).
  private var insideFilteredOsc: Bool = false

  // MARK: - Callbacks

  /// Callback invoked when a streaming message is parsed from PTY output.
  /// This enables real-time updates to ConversationView without file polling.
  public var onStreamingMessage: ((@Sendable (StreamingMessage) -> Void))?

  // MARK: - Initialization

  public init() {}

  // MARK: - Processing

  /// Process incoming terminal data, handling mode 2026 and OSC sequences.
  ///
  /// - Parameter data: Raw PTY output bytes
  /// - Returns: Data to forward to the terminal (filtered of mode 2026 and OSC 9 sequences)
  public func process(_ data: ArraySlice<UInt8>) -> [UInt8] {
    // If we're inside a filtered OSC sequence, look for terminator
    if insideFilteredOsc {
      var dataArray = Array(data)
      for i in 0..<dataArray.count {
        let byte = dataArray[i]
        // Check for BEL terminator
        if byte == Self.bel {
          insideFilteredOsc = false
          // Continue processing rest of data after terminator
          if i + 1 < dataArray.count {
            return process(ArraySlice(dataArray[(i + 1)...]))
          }
          return []
        }
        // Check for ST (ESC \) terminator
        if byte == 0x1B && i + 1 < dataArray.count && dataArray[i + 1] == 0x5C {
          insideFilteredOsc = false
          // Continue processing rest of data after terminator
          if i + 2 < dataArray.count {
            return process(ArraySlice(dataArray[(i + 2)...]))
          }
          return []
        }
      }
      // Still inside filtered OSC, consume all
      return []
    }

    // Fast path: if no ESC character and no pending partial, pass through
    if partialSequence.isEmpty && !data.contains(0x1B) {
      if isSyncEnabled {
        buffer.append(contentsOf: data)
        return []
      }
      return Array(data)
    }

    // Combine any partial sequence from previous chunk with new data
    var inputBytes: [UInt8]
    if !partialSequence.isEmpty {
      inputBytes = partialSequence + Array(data)
      partialSequence.removeAll()
    } else {
      inputBytes = Array(data)
    }

    var output: [UInt8] = []
    var index = 0

    while index < inputBytes.count {
      // Look for ESC character
      if inputBytes[index] == 0x1B {
        // Check if we have enough bytes for the full sequence
        let remaining = inputBytes.count - index

        // Check for DECSET (enable sync)
        if remaining >= Self.decsetSequence.count {
          if matchesSequence(inputBytes, at: index, sequence: Self.decsetSequence) {
            isSyncEnabled = true
            index += Self.decsetSequence.count
            continue
          }
        }

        // Check for DECRST (disable sync)
        if remaining >= Self.decrstSequence.count {
          if matchesSequence(inputBytes, at: index, sequence: Self.decrstSequence) {
            isSyncEnabled = false
            // Flush buffer when sync is disabled
            if !buffer.isEmpty {
              output.append(contentsOf: buffer)
              buffer.removeAll()
            }
            index += Self.decrstSequence.count
            continue
          }
        }

        // Check for OSC 9 sequence (ESC ] 9 ;) - filter to suppress SwiftTerm warning
        if remaining >= 4 && inputBytes[index + 1] == 0x5D {  // ESC ]
          // Check if it's OSC 9
          if inputBytes[index + 2] == 0x39 && inputBytes[index + 3] == 0x3B {  // '9' ';'
            // Enter filtered OSC mode, skip until BEL or ST
            index += 4
            while index < inputBytes.count {
              let byte = inputBytes[index]
              if byte == Self.bel {
                index += 1
                break
              }
              if byte == 0x1B && index + 1 < inputBytes.count && inputBytes[index + 1] == 0x5C {
                index += 2
                break
              }
              index += 1
            }
            // Check if we hit end of data without terminator
            if index >= inputBytes.count {
              insideFilteredOsc = true
            }
            continue
          }
        }

        // Check if this could be a partial sequence at the end of the chunk
        if remaining < Self.decsetSequence.count {
          // Check if the remaining bytes could be the start of a mode 2026 sequence
          if couldBeMode2026Prefix(Array(inputBytes[index...])) {
            // Save for next chunk
            partialSequence = Array(inputBytes[index...])
            break
          }
        }

        // Not a mode 2026 or filtered OSC sequence, pass through the ESC and continue
        if isSyncEnabled {
          buffer.append(inputBytes[index])
        } else {
          output.append(inputBytes[index])
        }
        index += 1
      } else {
        // Regular byte, buffer or output based on sync state
        if isSyncEnabled {
          buffer.append(inputBytes[index])
        } else {
          output.append(inputBytes[index])
        }
        index += 1
      }
    }

    return output
  }

  /// Flush any buffered content.
  /// - Returns: The buffered content that should be forwarded to the terminal.
  public func flush() -> [UInt8] {
    let result = buffer
    buffer.removeAll()
    return result
  }

  // MARK: - Private Helpers

  /// Check if the bytes at the given index match the target sequence.
  private func matchesSequence(_ bytes: [UInt8], at index: Int, sequence: [UInt8]) -> Bool {
    guard index + sequence.count <= bytes.count else { return false }
    for i in 0..<sequence.count {
      if bytes[index + i] != sequence[i] {
        return false
      }
    }
    return true
  }

  /// Check if the given bytes could be the prefix of a mode 2026 sequence.
  private func couldBeMode2026Prefix(_ bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty else { return false }

    // The DECSET and DECRST sequences only differ in the last byte
    // Common prefix: ESC [ ? 2 0 2 6
    let commonPrefix: [UInt8] = [0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36]

    // Check if bytes match the beginning of the common prefix
    for i in 0..<min(bytes.count, commonPrefix.count) {
      if bytes[i] != commonPrefix[i] {
        return false
      }
    }

    // If we've matched all bytes so far and haven't reached the end yet,
    // this could be a partial sequence
    if bytes.count <= commonPrefix.count {
      return true
    }

    // If we have the full prefix plus one more byte, check the final byte
    if bytes.count == commonPrefix.count + 1 {
      let lastByte = bytes[bytes.count - 1]
      return lastByte == 0x68 || lastByte == 0x6C  // 'h' or 'l'
    }

    return false
  }

  // MARK: - JSON Line Parsing (stream-json format)

  /// Processes raw PTY data and extracts JSON lines for streaming updates.
  /// Call this with the processed output from `process(_:)` to parse JSON messages.
  ///
  /// - Parameter data: Processed PTY output bytes (after mode 2026 filtering)
  public func parseJsonLines(_ data: [UInt8]) {
    guard onStreamingMessage != nil, !data.isEmpty else { return }

    // Convert bytes to string
    guard let text = String(data: Data(data), encoding: .utf8) else { return }

    // Combine with any buffered partial line
    let fullText = jsonLineBuffer + text

    // Split by newlines
    let lines = fullText.components(separatedBy: .newlines)

    // Process all complete lines (all but the last element)
    for i in 0..<(lines.count - 1) {
      let line = lines[i].trimmingCharacters(in: .whitespaces)
      if !line.isEmpty {
        parseJsonLine(line)
      }
    }

    // Save incomplete last line for next chunk
    jsonLineBuffer = lines.last ?? ""
  }

  /// Parses a single JSON line and invokes the callback if valid.
  private func parseJsonLine(_ line: String) {
    // Quick check: JSON objects start with {
    guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return }

    do {
      // Parse the JSON structure
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let typeString = json["type"] as? String else {
        return
      }

      let timestamp = Date()

      // Handle different message types from stream-json format
      switch typeString {
      case "user":
        if let message = parseUserMessage(json, timestamp: timestamp) {
          onStreamingMessage?(message)
        }

      case "assistant":
        // Assistant messages may contain text, tool_use, or thinking blocks
        parseAssistantMessage(json, timestamp: timestamp)

      case "result":
        if let message = parseResultMessage(json, timestamp: timestamp) {
          onStreamingMessage?(message)
        }

      default:
        // Log unknown types in debug mode
        #if DEBUG
        Self.logger.debug("[SyncOutput] Unknown stream-json type: \(typeString)")
        #endif
      }
    } catch {
      // Not valid JSON - that's OK, stream-json format may include non-JSON lines
      #if DEBUG
      Self.logger.debug("[SyncOutput] JSON parse error: \(error.localizedDescription)")
      #endif
    }
  }

  /// Parses a user message from stream-json format.
  private func parseUserMessage(_ json: [String: Any], timestamp: Date) -> StreamingMessage? {
    guard let message = json["message"] as? [String: Any] else { return nil }

    // Extract text from content array
    var textContent: String?
    if let content = message["content"] as? [[String: Any]] {
      for block in content {
        if let blockType = block["type"] as? String, blockType == "text",
           let text = block["text"] as? String {
          textContent = text
          break
        }
      }
    } else if let content = message["content"] as? String {
      textContent = content
    }

    return StreamingMessage(
      type: .user,
      timestamp: timestamp,
      textContent: textContent,
      toolUse: nil,
      toolResult: nil
    )
  }

  /// Parses assistant message content blocks and invokes callbacks for each.
  private func parseAssistantMessage(_ json: [String: Any], timestamp: Date) {
    guard let message = json["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]] else {
      return
    }

    for block in content {
      guard let blockType = block["type"] as? String else { continue }

      switch blockType {
      case "text":
        if let text = block["text"] as? String, !text.isEmpty {
          let message = StreamingMessage(
            type: .assistant,
            timestamp: timestamp,
            textContent: text,
            toolUse: nil,
            toolResult: nil
          )
          onStreamingMessage?(message)
        }

      case "tool_use":
        if let id = block["id"] as? String,
           let name = block["name"] as? String {
          // Extract input preview
          var inputPreview: String?
          if let input = block["input"] as? [String: Any] {
            if let filePath = input["file_path"] as? String {
              inputPreview = URL(fileURLWithPath: filePath).lastPathComponent
            } else if let command = input["command"] as? String {
              inputPreview = String(command.prefix(50))
            } else if let pattern = input["pattern"] as? String {
              inputPreview = pattern
            } else if let query = input["query"] as? String {
              inputPreview = String(query.prefix(50))
            }
          }

          let toolUse = StreamingMessage.ToolUseInfo(
            id: id,
            name: name,
            input: inputPreview
          )
          let message = StreamingMessage(
            type: .assistant,
            timestamp: timestamp,
            textContent: nil,
            toolUse: toolUse,
            toolResult: nil
          )
          onStreamingMessage?(message)
        }

      case "thinking":
        // Emit thinking indicator
        let message = StreamingMessage(
          type: .assistant,
          timestamp: timestamp,
          textContent: nil,
          toolUse: nil,
          toolResult: nil
        )
        onStreamingMessage?(message)

      default:
        break
      }
    }
  }

  /// Parses a tool result message from stream-json format.
  private func parseResultMessage(_ json: [String: Any], timestamp: Date) -> StreamingMessage? {
    // Result messages indicate tool completion
    // Structure varies - look for tool_use_id or content with error indication
    guard let message = json["message"] as? [String: Any] else { return nil }

    var toolUseId: String?
    var success = true

    // Check for tool_use_id in content blocks
    if let content = message["content"] as? [[String: Any]] {
      for block in content {
        if let blockType = block["type"] as? String, blockType == "tool_result" {
          toolUseId = block["tool_use_id"] as? String
          // Check for error
          if let isError = block["is_error"] as? Bool {
            success = !isError
          } else if let resultContent = block["content"] as? String {
            success = !resultContent.lowercased().contains("error")
          }
          break
        }
      }
    }

    guard let id = toolUseId else { return nil }

    let toolResult = StreamingMessage.ToolResultInfo(
      toolUseId: id,
      success: success
    )

    return StreamingMessage(
      type: .result,
      timestamp: timestamp,
      textContent: nil,
      toolUse: nil,
      toolResult: toolResult
    )
  }
}
