//
//  MonitoringEditorState.swift
//  AgentHub
//

import AgentHubGitDiff
import Foundation

extension Notification.Name {
  /// Request the focused monitoring card to swap between Terminal and Files content modes.
  static let toggleMonitoringContentMode = Notification.Name("com.agenthub.toggleMonitoringContentMode")
}

public enum DiffDisplayMode: String, CaseIterable, Identifiable, Sendable {
  case inline
  case sidePanel

  public var id: String { rawValue }

  var label: String {
    switch self {
    case .inline: "Inline"
    case .sidePanel: "Side Panel"
    }
  }
}

public enum MonitoringCardContentMode: String, CaseIterable, Identifiable {
  case terminal
  case editor
  case diffs

  public var id: String { rawValue }

  var label: String {
    switch self {
    case .terminal: "Terminal"
    case .editor: "Files"
    case .diffs: "Diffs"
    }
  }

  var systemImage: String {
    switch self {
    case .terminal: "terminal"
    case .editor: "doc.text"
    case .diffs: "arrow.left.arrow.right"
    }
  }
}

public struct FileExplorerNavigationRequest: Equatable {
  public let id: UUID
  public let filePath: String
  public let lineNumber: Int?

  public init(
    filePath: String,
    lineNumber: Int? = nil,
    id: UUID = UUID()
  ) {
    self.id = id
    self.filePath = filePath
    self.lineNumber = lineNumber
  }
}

struct MonitoringEditorState: Equatable {
  var contentMode: MonitoringCardContentMode = .terminal
  var projectPath: String
  var selectedFilePath: String?
  var navigationRequest: FileExplorerNavigationRequest?
}

struct MonitoringEditorRouteResult {
  let states: [String: MonitoringEditorState]
  let primaryItemID: String?
}

enum MonitoringEditorStateStore {
  static func availableContentModes(
    diffDisplayMode: DiffDisplayMode,
    diffAvailabilityStatus: DiffAvailabilityStatus?
  ) -> [MonitoringCardContentMode] {
    var modes: [MonitoringCardContentMode] = [.terminal, .editor]
    if diffDisplayMode == .inline,
       diffAvailabilityStatus?.isAvailable == true {
      modes.append(.diffs)
    }
    return modes
  }

  static func coercedContentMode(
    _ contentMode: MonitoringCardContentMode,
    availableModes: [MonitoringCardContentMode]
  ) -> MonitoringCardContentMode {
    availableModes.contains(contentMode) ? contentMode : .terminal
  }

  static func toggledTerminalFilesMode(
    from contentMode: MonitoringCardContentMode
  ) -> MonitoringCardContentMode {
    contentMode == .terminal ? .editor : .terminal
  }

  static func state(
    for itemID: String,
    defaultProjectPath: String,
    in states: [String: MonitoringEditorState]
  ) -> MonitoringEditorState {
    states[itemID] ?? MonitoringEditorState(projectPath: defaultProjectPath)
  }

  static func setContentMode(
    _ contentMode: MonitoringCardContentMode,
    for itemID: String,
    defaultProjectPath: String,
    in states: [String: MonitoringEditorState]
  ) -> [String: MonitoringEditorState] {
    var updatedStates = states
    var state = state(for: itemID, defaultProjectPath: defaultProjectPath, in: updatedStates)
    state.contentMode = contentMode
    updatedStates[itemID] = state
    return updatedStates
  }

  static func setSelectedFilePath(
    _ selectedFilePath: String?,
    for itemID: String,
    defaultProjectPath: String,
    in states: [String: MonitoringEditorState]
  ) -> [String: MonitoringEditorState] {
    var updatedStates = states
    var state = state(for: itemID, defaultProjectPath: defaultProjectPath, in: updatedStates)
    state.selectedFilePath = selectedFilePath
    state.navigationRequest = nil
    updatedStates[itemID] = state
    return updatedStates
  }

  static func openFile(
    _ filePath: String,
    lineNumber: Int? = nil,
    projectPath: String,
    for itemID: String,
    in states: [String: MonitoringEditorState]
  ) -> [String: MonitoringEditorState] {
    var updatedStates = states
    var state = self.state(for: itemID, defaultProjectPath: projectPath, in: updatedStates)
    state.projectPath = projectPath
    state.contentMode = .editor
    state.selectedFilePath = filePath
    state.navigationRequest = FileExplorerNavigationRequest(
      filePath: filePath,
      lineNumber: lineNumber
    )
    updatedStates[itemID] = state
    return updatedStates
  }

  static func routeOpenFile(
    _ filePath: String,
    lineNumber: Int? = nil,
    projectPath: String,
    for itemID: String,
    in states: [String: MonitoringEditorState],
    currentPrimaryItemID: String?,
    makePrimary: Bool
  ) -> MonitoringEditorRouteResult {
    MonitoringEditorRouteResult(
      states: openFile(
        filePath,
        lineNumber: lineNumber,
        projectPath: projectPath,
        for: itemID,
        in: states
      ),
      primaryItemID: makePrimary ? itemID : currentPrimaryItemID
    )
  }

  static func prune(
    _ states: [String: MonitoringEditorState],
    validItemIDs: Set<String>
  ) -> [String: MonitoringEditorState] {
    states.filter { validItemIDs.contains($0.key) }
  }
}
