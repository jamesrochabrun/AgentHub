//
//  YAMLThemeParser.swift
//  AgentHub
//
//  Parser and validator for YAML theme files
//

import Foundation
import Yams

public enum ThemeError: LocalizedError {
  case fileNotFound(String)
  case invalidYAML(String)
  case missingRequiredField(String)
  case invalidColorFormat(String, String)

  public var errorDescription: String? {
    switch self {
    case .fileNotFound(let path):
      return "Theme file not found: \(path)"
    case .invalidYAML(let error):
      return "Invalid YAML: \(error)"
    case .missingRequiredField(let field):
      return "Missing required field: \(field)"
    case .invalidColorFormat(let color, let field):
      return "Invalid color '\(color)' for \(field). Use hex format like #RRGGBB"
    }
  }
}

public struct YAMLThemeParser {
  public init() {}

  public func parse(data: Data) throws -> YAMLTheme {
    guard let yamlString = String(data: data, encoding: .utf8) else {
      throw ThemeError.invalidYAML("Could not decode file as UTF-8")
    }

    let decoder = YAMLDecoder()
    do {
      let theme = try decoder.decode(YAMLTheme.self, from: yamlString)
      try validate(theme)
      return theme
    } catch let error as DecodingError {
      throw ThemeError.invalidYAML(error.localizedDescription)
    }
  }

  public func parse(fileURL: URL) throws -> YAMLTheme {
    let data = try Data(contentsOf: fileURL)
    return try parse(data: data)
  }

  private func validate(_ theme: YAMLTheme) throws {
    guard !theme.name.isEmpty else {
      throw ThemeError.missingRequiredField("name")
    }

    // Validate brand colors (required)
    try validateColor(theme.colors.brand.primary, field: "colors.brand.primary")
    try validateColor(theme.colors.brand.secondary, field: "colors.brand.secondary")
    try validateColor(theme.colors.brand.tertiary, field: "colors.brand.tertiary")

    // Validate optional background colors
    if let bg = theme.colors.backgrounds {
      if let dark = bg.dark { try validateColor(dark, field: "colors.backgrounds.dark") }
      if let light = bg.light { try validateColor(light, field: "colors.backgrounds.light") }
      if let expandedDark = bg.expandedContentDark {
        try validateColor(expandedDark, field: "colors.backgrounds.expandedContentDark")
      }
      if let expandedLight = bg.expandedContentLight {
        try validateColor(expandedLight, field: "colors.backgrounds.expandedContentLight")
      }
    }

    // Validate gradient colors
    if let gradient = theme.colors.backgroundGradient {
      for (index, stop) in gradient.enumerated() {
        try validateColor(stop.color, field: "colors.backgroundGradient[\(index)].color")
        guard stop.opacity >= 0 && stop.opacity <= 1 else {
          throw ThemeError.invalidYAML("Gradient opacity must be between 0 and 1")
        }
      }
    }
  }

  private func validateColor(_ hex: String, field: String) throws {
    // Support #RRGGBB or RRGGBB format
    let pattern = "^#?[0-9A-Fa-f]{6}$"
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(hex.startIndex..., in: hex)

    guard regex.firstMatch(in: hex, range: range) != nil else {
      throw ThemeError.invalidColorFormat(hex, field)
    }
  }
}
