//
//  CodexTimestampParser.swift
//  AgentHubSessionGraph
//
//  Fast parser for the UTC timestamp shapes written by Codex JSONL files.
//

import Foundation

public enum CodexTimestampParser {
  public static func parse(_ string: String?) -> Date? {
    guard let string else { return nil }
    if let date = parseCommonUTCString(string) {
      return date
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  private static func parseCommonUTCString(_ string: String) -> Date? {
    string.utf8.withContiguousStorageIfAvailable { bytes in
      parseCommonUTCBytes(bytes)
    } ?? parseCommonUTCBytes(Array(string.utf8))
  }

  private static func parseCommonUTCBytes<C: Collection>(_ bytes: C) -> Date?
    where C.Element == UInt8, C.Index == Int {
    guard bytes.count == 20 || bytes.count >= 22 else { return nil }
    guard bytes[4] == asciiHyphen,
          bytes[7] == asciiHyphen,
          bytes[10] == asciiT,
          bytes[13] == asciiColon,
          bytes[16] == asciiColon else {
      return nil
    }

    let year = digits(bytes, 0, 4)
    let month = digits(bytes, 5, 2)
    let day = digits(bytes, 8, 2)
    let hour = digits(bytes, 11, 2)
    let minute = digits(bytes, 14, 2)
    let second = digits(bytes, 17, 2)

    guard year >= 0,
          (1...12).contains(month),
          day >= 1,
          day <= daysInMonth(year: year, month: month),
          (0...23).contains(hour),
          (0...59).contains(minute),
          (0...59).contains(second) else {
      return nil
    }

    let fractionalSeconds: Double
    if bytes.count == 20 {
      guard bytes[19] == asciiZ else { return nil }
      fractionalSeconds = 0
    } else {
      guard bytes[19] == asciiPeriod,
            bytes[bytes.count - 1] == asciiZ else {
        return nil
      }

      var value = 0
      var divisor = 1
      var index = 20
      while index < bytes.count - 1 {
        guard let digit = digitValue(bytes[index]) else { return nil }
        if divisor < 1_000_000_000 {
          value = value * 10 + digit
          divisor *= 10
        }
        index += 1
      }
      guard index > 20 else { return nil }
      fractionalSeconds = Double(value) / Double(divisor)
    }

    let days = daysFromCivil(year: year, month: month, day: day)
    let wholeSeconds = days * 86_400 + hour * 3_600 + minute * 60 + second
    return Date(timeIntervalSince1970: TimeInterval(wholeSeconds) + fractionalSeconds)
  }

  private static func digits<C: Collection>(_ bytes: C, _ start: Int, _ count: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
    var value = 0
    for index in start..<(start + count) {
      guard let digit = digitValue(bytes[index]) else { return -1 }
      value = value * 10 + digit
    }
    return value
  }

  private static func digitValue(_ byte: UInt8) -> Int? {
    guard byte >= asciiZero, byte <= asciiNine else { return nil }
    return Int(byte - asciiZero)
  }

  private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    var adjustedYear = year
    adjustedYear -= month <= 2 ? 1 : 0
    let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
    let yearOfEra = adjustedYear - era * 400
    let monthPrime = month + (month > 2 ? -3 : 9)
    let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12:
      return 31
    case 4, 6, 9, 11:
      return 30
    case 2:
      return isLeapYear(year) ? 29 : 28
    default:
      return 0
    }
  }

  private static func isLeapYear(_ year: Int) -> Bool {
    year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
  }

  private static let asciiZero = UInt8(ascii: "0")
  private static let asciiNine = UInt8(ascii: "9")
  private static let asciiHyphen = UInt8(ascii: "-")
  private static let asciiT = UInt8(ascii: "T")
  private static let asciiColon = UInt8(ascii: ":")
  private static let asciiPeriod = UInt8(ascii: ".")
  private static let asciiZ = UInt8(ascii: "Z")
}
