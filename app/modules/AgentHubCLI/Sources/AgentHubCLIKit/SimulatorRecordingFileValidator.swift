import Foundation

struct SimulatorRecordingFileValidation: Equatable, Sendable {
  let fileExists: Bool
  let fileSizeBytes: Int64?
  let topLevelBoxes: Set<String>
  let readError: String?

  var isFinalized: Bool {
    fileExists
      && (fileSizeBytes ?? 0) > 0
      && readError == nil
      && topLevelBoxes.contains("ftyp")
      && topLevelBoxes.contains("mdat")
      && topLevelBoxes.contains("moov")
  }

  var errorDescription: String? {
    guard !isFinalized else { return nil }
    guard fileExists else {
      return "The expected MP4 file was not created."
    }
    guard let fileSizeBytes, fileSizeBytes > 0 else {
      return "The MP4 file is empty."
    }
    if let readError {
      return "The MP4 file could not be inspected: \(readError)"
    }

    let missingBoxes = ["ftyp", "mdat", "moov"].filter { !topLevelBoxes.contains($0) }
    if !missingBoxes.isEmpty {
      return "The MP4 file did not finalize correctly; missing top-level \(missingBoxes.joined(separator: ", ")) atom(s)."
    }
    return "The MP4 file did not finalize correctly."
  }
}

enum SimulatorRecordingFileValidator {
  static func validate(
    url: URL,
    fileManager: FileManager = .default
  ) -> SimulatorRecordingFileValidation {
    guard fileManager.fileExists(atPath: url.path) else {
      return SimulatorRecordingFileValidation(
        fileExists: false,
        fileSizeBytes: nil,
        topLevelBoxes: [],
        readError: nil
      )
    }

    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
    guard let fileSize, fileSize > 0 else {
      return SimulatorRecordingFileValidation(
        fileExists: true,
        fileSizeBytes: fileSize,
        topLevelBoxes: [],
        readError: nil
      )
    }

    do {
      return SimulatorRecordingFileValidation(
        fileExists: true,
        fileSizeBytes: fileSize,
        topLevelBoxes: try topLevelBoxes(in: url, fileSize: UInt64(fileSize)),
        readError: nil
      )
    } catch {
      return SimulatorRecordingFileValidation(
        fileExists: true,
        fileSizeBytes: fileSize,
        topLevelBoxes: [],
        readError: error.localizedDescription
      )
    }
  }

  private static func topLevelBoxes(in url: URL, fileSize: UInt64) throws -> Set<String> {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var boxes: Set<String> = []
    var offset: UInt64 = 0

    while offset + 8 <= fileSize {
      try handle.seek(toOffset: offset)
      guard let header = try handle.read(upToCount: 8), header.count == 8 else {
        break
      }

      let boxType = String(data: header.subdata(in: 4..<8), encoding: .ascii) ?? "????"
      var headerSize: UInt64 = 8
      var boxSize = uint32(header, at: 0)

      if boxSize == 1 {
        guard let extendedSizeData = try handle.read(upToCount: 8),
              extendedSizeData.count == 8 else {
          throw SimulatorRecordingFileValidatorError.truncatedBoxHeader(boxType)
        }
        boxSize = uint64(extendedSizeData, at: 0)
        headerSize = 16
      } else if boxSize == 0 {
        boxSize = fileSize - offset
      }

      guard boxSize >= headerSize else {
        throw SimulatorRecordingFileValidatorError.invalidBoxSize(boxType)
      }
      guard boxSize > 0 else {
        break
      }

      boxes.insert(boxType)
      let nextOffset = offset + boxSize
      guard nextOffset > offset else {
        throw SimulatorRecordingFileValidatorError.invalidBoxSize(boxType)
      }
      offset = nextOffset
    }

    return boxes
  }

  private static func uint32(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in data.dropFirst(offset).prefix(4) {
      value = (value << 8) | UInt64(byte)
    }
    return value
  }

  private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in data.dropFirst(offset).prefix(8) {
      value = (value << 8) | UInt64(byte)
    }
    return value
  }
}

private enum SimulatorRecordingFileValidatorError: LocalizedError {
  case truncatedBoxHeader(String)
  case invalidBoxSize(String)

  var errorDescription: String? {
    switch self {
    case .truncatedBoxHeader(let box):
      return "Truncated extended-size header for \(box) atom."
    case .invalidBoxSize(let box):
      return "Invalid size for \(box) atom."
    }
  }
}
