//
//  MonitoringEditorState.swift
//  AgentHub
//

import Foundation

public enum MonitoringCardContentMode: String, CaseIterable, Identifiable {
  case terminal
  case editor

  public var id: String { rawValue }

  var label: String {
    switch self {
    case .terminal: "Terminal"
    case .editor: "Code"
    }
  }

  var systemImage: String {
    switch self {
    case .terminal: "terminal"
    case .editor: "doc.text"
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
