//
//  TextFileMetrics.swift
//  AgentHub
//
//  Lightweight metrics used to select an editor mode before expensive editor
//  features are enabled.
//

import Foundation

public struct TextFileMetrics: Equatable, Sendable {
  public let byteCount: Int
  public let lineCount: Int
  public let maxLineByteCount: Int

  public init(byteCount: Int, lineCount: Int, maxLineByteCount: Int) {
    self.byteCount = byteCount
    self.lineCount = lineCount
    self.maxLineByteCount = maxLineByteCount
  }

  public static func metrics(forUTF8Data data: Data) -> TextFileMetrics {
    metrics(forUTF8Bytes: data, byteCount: data.count)
  }

  public static func metrics(for content: String) -> TextFileMetrics {
    metrics(forUTF8Bytes: content.utf8, byteCount: content.utf8.count)
  }

  private static func metrics<Bytes: Sequence>(
    forUTF8Bytes bytes: Bytes,
    byteCount: Int
  ) -> TextFileMetrics where Bytes.Element == UInt8 {
    guard byteCount > 0 else {
      return TextFileMetrics(byteCount: 0, lineCount: 0, maxLineByteCount: 0)
    }

    var lineCount = 1
    var currentLineByteCount = 0
    var maxLineByteCount = 0

    for byte in bytes {
      if byte == 0x0A {
        maxLineByteCount = max(maxLineByteCount, currentLineByteCount)
        currentLineByteCount = 0
        lineCount += 1
      } else {
        currentLineByteCount += 1
      }
    }

    maxLineByteCount = max(maxLineByteCount, currentLineByteCount)
    return TextFileMetrics(
      byteCount: byteCount,
      lineCount: lineCount,
      maxLineByteCount: maxLineByteCount
    )
  }
}

struct ProjectTextFile: Sendable {
  let content: String
  let metrics: TextFileMetrics
}
