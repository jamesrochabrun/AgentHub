//
//  TerminalPromptSubmissionPayload.swift
//  AgentHub
//
//  Created by Assistant on 4/8/26.
//

import Foundation

enum TerminalPromptSubmissionPayload {
  private static let carriageReturn: UInt8 = 0x0D
  private static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
  private static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

  static func bytes(prompt: String, bracketedPasteMode: Bool) -> [UInt8] {
    var payload = textBytes(prompt: prompt, bracketedPasteMode: bracketedPasteMode)
    payload.append(carriageReturn)
    return payload
  }

  /// Returns the prompt wrapped in bracketed-paste markers (when active)
  /// but WITHOUT the trailing carriage return. Callers that need a delay
  /// between paste-end and submit can send CR separately.
  static func textBytes(prompt: String, bracketedPasteMode: Bool) -> [UInt8] {
    var payload: [UInt8] = []
    if bracketedPasteMode {
      payload.append(contentsOf: bracketedPasteStart)
    }
    payload.append(contentsOf: prompt.utf8)
    if bracketedPasteMode {
      payload.append(contentsOf: bracketedPasteEnd)
    }
    return payload
  }
}
