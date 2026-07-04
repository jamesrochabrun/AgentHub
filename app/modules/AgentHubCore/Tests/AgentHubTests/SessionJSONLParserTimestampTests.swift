import Foundation
import Testing

@testable import AgentHubCore

/// Parity tests for `SessionJSONLParser`'s timestamp parsing, which now uses the
/// `CodexTimestampParser` byte-scan fast path for the common UTC shapes Claude Code
/// writes, with the original fractional-then-plain `ISO8601DateFormatter` sequence as
/// fallback for exotic strings. Timestamps are exercised through the public
/// `parseNewLines` API and observed via `sessionStartedAt` / `lastActivityAt`.
@Suite("SessionJSONLParser timestamp parsing")
struct SessionJSONLParserTimestampTests {

  @Test("Fast path matches formatter for non-fractional UTC timestamps")
  func nonFractionalUTC() throws {
    let string = "2026-05-05T12:00:00Z"
    let parsed = try #require(parsedDate(forTimestamp: string))
    let expected = try #require(iso8601Reference(string))
    #expect(parsed == expected)
  }

  @Test("Fast path matches formatter for millisecond UTC timestamps")
  func millisecondFractionUTC() throws {
    let string = "2026-05-05T12:00:00.123Z"
    let parsed = try #require(parsedDate(forTimestamp: string))
    let expected = try #require(iso8601Reference(string))
    #expect(abs(parsed.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.000_001)
  }

  @Test("Fast path stays within a millisecond of the formatter for microsecond fractions")
  func microsecondFractionUTC() throws {
    // ISO8601DateFormatter truncates parsing to millisecond precision; the byte-scan
    // fast path keeps the full fraction, so allow sub-millisecond drift.
    let string = "2026-05-05T12:00:00.123456Z"
    let parsed = try #require(parsedDate(forTimestamp: string))
    let expected = try #require(iso8601Reference(string))
    #expect(abs(parsed.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.001)
  }

  @Test("Falls back to the formatter for timezone-offset timestamps")
  func offsetTimestamps() throws {
    for string in ["2026-05-05T12:00:00+01:00", "2026-05-05T12:00:00.500+01:00"] {
      let parsed = try #require(parsedDate(forTimestamp: string))
      let expected = try #require(iso8601Reference(string))
      #expect(parsed == expected)
    }
  }

  @Test("Garbage timestamps leave activity dates unset")
  func garbageTimestamps() {
    for string in ["not-a-date", "", "2026-05-05 12:00:00"] {
      var result = SessionJSONLParser.ParseResult()
      SessionJSONLParser.parseNewLines([line(withTimestamp: string)], into: &result)
      #expect(result.sessionStartedAt == nil)
      #expect(result.lastActivityAt == nil)
    }
  }

  @Test("Invalid calendar dates keep parity with the lenient formatter fallback")
  func invalidCalendarDate() {
    // The fast path rejects impossible dates (Feb 31) and defers to the formatter
    // fallback — on OS versions where ISO8601DateFormatter is lenient this rolls
    // over instead of returning nil, exactly as the pre-fast-path code did. Assert
    // parity with the reference chain rather than a fixed outcome.
    let string = "2026-02-31T12:00:00Z"
    #expect(parsedDate(forTimestamp: string) == iso8601Reference(string))
  }

  @Test("Session start and last activity use the same parsed timestamp")
  func sessionStartMatchesLastActivityForSingleEntry() throws {
    let string = "2026-05-05T12:00:00.123Z"
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line(withTimestamp: string)], into: &result)
    let started = try #require(result.sessionStartedAt)
    let last = try #require(result.lastActivityAt)
    #expect(started == last)
  }

  // MARK: - Helpers

  private func line(withTimestamp timestamp: String) -> String {
    """
    {"type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
    """
  }

  private func parsedDate(forTimestamp timestamp: String) -> Date? {
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line(withTimestamp: timestamp)], into: &result)
    return result.lastActivityAt
  }

  /// Mirrors the documented fallback: fractional ISO8601 first, then plain.
  private func iso8601Reference(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) {
      return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}
