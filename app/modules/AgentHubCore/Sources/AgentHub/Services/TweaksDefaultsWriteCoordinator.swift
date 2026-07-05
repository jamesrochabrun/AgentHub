//
//  TweaksDefaultsWriteCoordinator.swift
//  AgentHub
//
//  Debounced persistence for Canvas tweakable-prop values. Live changes are
//  applied in the WKWebView immediately; this coordinator makes direct-file
//  HTML/SVG previews keep the latest value as the next declared default.
//

import Canvas
import Foundation

enum TweaksDefaultsWriteOutcome: Equatable, Sendable {
  case written
  case noChange
  case invalidPropName
  case propNotDeclared
  case editFailed(String)
}

actor TweaksDefaultsWriteCoordinator {
  static let debounceDuration: Duration = .milliseconds(350)
  static let reloadSuppressionDuration: TimeInterval = 1.5

  private let fileService: any ProjectFileServiceProtocol
  private let debounceDuration: Duration
  private var pendingWriteTask: Task<Void, Never>?

  init(
    fileService: any ProjectFileServiceProtocol = ProjectFileService.shared,
    debounceDuration: Duration = TweaksDefaultsWriteCoordinator.debounceDuration
  ) {
    self.fileService = fileService
    self.debounceDuration = debounceDuration
  }

  deinit {
    pendingWriteTask?.cancel()
  }

  func scheduleValueWrite(
    propName: String,
    value: TweakPropValue,
    filePath: String,
    projectPath: String
  ) {
    pendingWriteTask?.cancel()
    pendingWriteTask = Task { [debounceDuration] in
      try? await Task.sleep(for: debounceDuration)
      guard !Task.isCancelled else { return }
      _ = await self.writeValue(
        propName: propName,
        value: value,
        filePath: filePath,
        projectPath: projectPath
      )
    }
  }

  func cancelPendingWrite() {
    pendingWriteTask?.cancel()
    pendingWriteTask = nil
  }

  func writeValue(
    propName: String,
    value: TweakPropValue,
    filePath: String,
    projectPath: String
  ) async -> TweaksDefaultsWriteOutcome {
    guard Self.isValidPropName(propName) else { return .invalidPropName }

    let source: String
    do {
      source = try await fileService.readFile(at: filePath, projectPath: projectPath)
    } catch {
      return .editFailed("Could not read \(filePath): \(error.localizedDescription)")
    }

    do {
      let declaredNames = try TweakPropsSourceEditor.parsePropNames(fromSource: source)
      guard declaredNames.contains(propName) else { return .propNotDeclared }

      let edited = try TweakPropsSourceEditor.applyingValueEdit(
        propName: propName,
        newValue: value,
        toSource: source
      )
      guard edited != source else { return .noChange }

      let verifiedProps = try TweakPropsSourceEditor.parseProps(fromSource: edited)
      guard verifiedProps.contains(where: { $0.name == propName && $0.value == value }) else {
        return .editFailed("Edited source failed tweak prop verification")
      }

      try await fileService.writeFile(at: filePath, content: edited, projectPath: projectPath)
      return .written
    } catch TweakPropsSourceEditorError.propNotFound {
      return .propNotDeclared
    } catch {
      return .editFailed("Tweak default edit rejected: \(error)")
    }
  }

  static func isValidPropName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 80 else { return false }
    return name.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 48...57, 65...90, 97...122:
        return true
      case 36, 45, 95:
        return true
      default:
        return false
      }
    }
  }
}
