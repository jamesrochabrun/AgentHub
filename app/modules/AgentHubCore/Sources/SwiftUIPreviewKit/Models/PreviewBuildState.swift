//
//  PreviewBuildState.swift
//  SwiftUIPreviewKit
//
//  State enum for the preview build pipeline and generated host project info.
//

import Foundation

public enum PreviewBuildState: Equatable, Sendable {
  case idle
  case scanningPreviews
  case buildingUserProject
  case generatingHost
  case buildingHost
  case installing
  case capturing
  case ready(imagePath: String)
  case failed(error: String)

  public var isBuilding: Bool {
    switch self {
    case .buildingUserProject, .generatingHost, .buildingHost, .installing, .capturing:
      return true
    default:
      return false
    }
  }

  public var phaseLabel: String? {
    switch self {
    case .scanningPreviews: return "Scanning previews…"
    case .buildingUserProject: return "Building project…"
    case .generatingHost: return "Generating preview host…"
    case .buildingHost: return "Building preview…"
    case .installing: return "Installing on simulator…"
    case .capturing: return "Capturing screenshot…"
    default: return nil
    }
  }
}

public struct GeneratedPreviewHost: Sendable {
  public let projectPath: String
  public let scheme: String
  public let bundleIdentifier: String
  public let derivedDataPath: String

  public init(
    projectPath: String,
    scheme: String,
    bundleIdentifier: String,
    derivedDataPath: String
  ) {
    self.projectPath = projectPath
    self.scheme = scheme
    self.bundleIdentifier = bundleIdentifier
    self.derivedDataPath = derivedDataPath
  }
}
