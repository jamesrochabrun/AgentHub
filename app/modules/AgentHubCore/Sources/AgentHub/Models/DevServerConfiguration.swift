//
//  DevServerConfiguration.swift
//  AgentHub
//
//  Data types for dev server project detection and state management.
//

import Foundation

// MARK: - ProjectFramework

/// Detected web framework type based on package.json analysis
enum ProjectFramework: String, Sendable {
  case vite
  case nextjs
  case createReactApp
  case angular
  case vueCLI
  case astro
  case staticHTML
  case unknown

  /// Whether this framework requires a dev server for transpilation/bundling
  var requiresDevServer: Bool {
    switch self {
    case .vite, .nextjs, .createReactApp, .angular, .vueCLI, .astro:
      return true
    case .staticHTML, .unknown:
      return false
    }
  }

  /// Fast synchronous detection of project framework from package.json
  static func detect(at projectPath: String) -> ProjectFramework {
    let fm = FileManager.default
    let packageJsonPath = "\(projectPath)/package.json"

    guard fm.fileExists(atPath: packageJsonPath),
          let data = fm.contents(atPath: packageJsonPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .staticHTML
    }

    let scripts = json["scripts"] as? [String: String] ?? [:]
    let deps = json["dependencies"] as? [String: Any] ?? [:]
    let devDeps = json["devDependencies"] as? [String: Any] ?? [:]
    let allDeps = deps.merging(devDeps) { a, _ in a }

    if allDeps["vite"] != nil || scripts["dev"]?.contains("vite") == true {
      return .vite
    }
    if allDeps["next"] != nil {
      return .nextjs
    }
    if allDeps["react-scripts"] != nil {
      return .createReactApp
    }
    if allDeps["@angular/core"] != nil {
      return .angular
    }
    if allDeps["@vue/cli-service"] != nil {
      return .vueCLI
    }
    if allDeps["astro"] != nil {
      return .astro
    }

    // Has package.json with dev/start scripts but no recognized framework
    if scripts["dev"] != nil || scripts["start"] != nil {
      return .unknown
    }

    return .staticHTML
  }
}

// MARK: - DetectedProject

/// Result of analyzing a project directory to determine how to start a dev server
struct DetectedProject: Sendable {
  /// The detected framework
  let framework: ProjectFramework
  /// Command to execute (e.g. "npm", "python3")
  let command: String
  /// Arguments for the command (e.g. ["run", "dev", "--", "--port"])
  let arguments: [String]
  /// Default port for this framework
  let defaultPort: Int
  /// Stdout/stderr patterns that indicate the server is ready
  let readinessPatterns: [String]
}

// MARK: - DevServerState

/// Observable state of a dev server for a given project path
public enum DevServerState: Equatable, Sendable {
  case idle
  case detecting
  case starting(message: String)
  case waitingForReady
  case ready(url: URL)
  case failed(error: String)
  case stopping

  public static func == (lhs: DevServerState, rhs: DevServerState) -> Bool {
    switch (lhs, rhs) {
    case (.idle, .idle): return true
    case (.detecting, .detecting): return true
    case (.starting(let a), .starting(let b)): return a == b
    case (.waitingForReady, .waitingForReady): return true
    case (.ready(let a), .ready(let b)): return a == b
    case (.failed(let a), .failed(let b)): return a == b
    case (.stopping, .stopping): return true
    default: return false
    }
  }
}
