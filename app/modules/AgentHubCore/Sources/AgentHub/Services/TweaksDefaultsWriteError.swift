//
//  TweaksDefaultsWriteError.swift
//  AgentHub
//

import Foundation

enum TweaksDefaultsWriteError: LocalizedError, Equatable {
  case cannotReadFile
  case sourceChanged
  case unsupportedValue(String)
  case writeFailed(String)

  var errorDescription: String? {
    switch self {
    case .cannotReadFile:
      return "The preview file could not be read."
    case .sourceChanged:
      return "The tweak defaults changed on disk. Reload the preview and try again."
    case .unsupportedValue(let propName):
      return "\(propName) does not use a literal value that can be saved as a default."
    case .writeFailed(let message):
      return "The new defaults could not be saved: \(message)"
    }
  }
}
