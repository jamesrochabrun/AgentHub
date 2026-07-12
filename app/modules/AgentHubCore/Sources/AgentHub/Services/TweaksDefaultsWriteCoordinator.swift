//
//  TweaksDefaultsWriteCoordinator.swift
//  AgentHub
//
//  Explicitly promotes live Canvas tweak values to source defaults after
//  verifying that the source still matches the preview's loaded baseline.
//

import Canvas
import Foundation

protocol TweaksDefaultsWriting: Sendable {
  func saveDefaults(
    props: [TweakProp],
    filePath: String,
    projectPath: String
  ) async throws
}

actor TweaksDefaultsWriteCoordinator: TweaksDefaultsWriting {
  static let reloadSuppressionDuration: TimeInterval = 1.5

  private let fileService: any ProjectFileServiceProtocol

  init(fileService: any ProjectFileServiceProtocol = ProjectFileService.shared) {
    self.fileService = fileService
  }

  static func resolveFilePath(previewURL: URL, projectPath: String) -> String? {
    if previewURL.isFileURL {
      return previewURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
    guard let scheme = previewURL.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return nil
    }

    var relativePath = previewURL.path
    if relativePath.isEmpty || relativePath == "/" {
      relativePath = "/index.html"
    } else if previewURL.hasDirectoryPath {
      relativePath += "/index.html"
    }
    return (projectPath as NSString).appendingPathComponent(relativePath)
  }

  func saveDefaults(
    props: [TweakProp],
    filePath: String,
    projectPath: String
  ) async throws {
    let changedProps = props.filter { $0.value != $0.defaultValue }
    guard !changedProps.isEmpty else { return }

    let source: String
    do {
      source = try await fileService.readFile(at: filePath, projectPath: projectPath)
    } catch {
      throw TweaksDefaultsWriteError.cannotReadFile
    }

    guard let diskNames = try? TweakPropsSourceEditor.parsePropNames(fromSource: source),
          diskNames == props.map(\.name),
          let diskProps = try? TweakPropsSourceEditor.parseProps(fromSource: source) else {
      throw TweaksDefaultsWriteError.sourceChanged
    }

    let diskPropsByName = Dictionary(uniqueKeysWithValues: diskProps.map { ($0.name, $0) })
    for prop in props {
      guard let diskProp = diskPropsByName[prop.name] else {
        throw TweaksDefaultsWriteError.unsupportedValue(prop.name)
      }
      guard diskProp == sourceBaseline(for: prop) else {
        throw TweaksDefaultsWriteError.sourceChanged
      }
    }

    var edited = source
    for prop in changedProps {
      do {
        edited = try TweakPropsSourceEditor.applyingValueEdit(
          propName: prop.name,
          newValue: prop.value,
          toSource: edited
        )
      } catch {
        throw TweaksDefaultsWriteError.unsupportedValue(prop.name)
      }
    }
    guard edited != source else { return }

    do {
      try await fileService.writeFile(at: filePath, content: edited, projectPath: projectPath)
    } catch {
      throw TweaksDefaultsWriteError.writeFailed(error.localizedDescription)
    }
  }

  private func sourceBaseline(for prop: TweakProp) -> TweakProp {
    TweakProp(
      name: prop.name,
      label: prop.label,
      type: prop.type,
      minimum: prop.minimum,
      maximum: prop.maximum,
      step: prop.step,
      options: prop.options,
      value: prop.defaultValue,
      defaultValue: prop.defaultValue
    )
  }
}
