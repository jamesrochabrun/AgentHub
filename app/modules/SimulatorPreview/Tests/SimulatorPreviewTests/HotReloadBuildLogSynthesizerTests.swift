import Foundation
import Testing

@testable import SimulatorPreview

@Suite("HotReloadBuildLogSynthesizer")
struct HotReloadBuildLogSynthesizerTests {

  private func gunzip(_ url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    process.arguments = ["-c", url.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  @Test("writes a gunzip-able log containing only the frontend command lines")
  func synthesizesLog() throws {
    let derivedData = FileManager.default.temporaryDirectory
      .appendingPathComponent("dd-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: derivedData) }

    let buildOutput = """
    Build description path: /tmp/whatever
    CompileSwift normal arm64 (in target 'MathGame')
    /Applications/Xcode.app/.../swift-frontend -frontend -c /p/A.swift /p/B.swift -primary-file /p/A.swift -emit-module -o /dd/A.o
    note: something else
    /Applications/Xcode.app/.../swift-frontend -frontend -c /p/A.swift /p/B.swift -primary-file /p/B.swift -o /dd/B.o
    ** BUILD SUCCEEDED **
    """
    let logURL = try HotReloadBuildLogSynthesizer.writeSyntheticLog(
      buildOutput: Data(buildOutput.utf8),
      derivedDataPath: derivedData.path
    )

    let unwrapped = try #require(logURL)
    #expect(unwrapped.pathExtension == "xcactivitylog")
    #expect(unwrapped.deletingLastPathComponent().path.hasSuffix("Logs/Build"))

    // The engine's discovery pipeline: gunzip | grep " -primary-file <file> ".
    let content = try gunzip(unwrapped)
    #expect(content.contains(" -primary-file /p/A.swift "))
    #expect(content.contains(" -primary-file /p/B.swift "))
    #expect(!content.contains("BUILD SUCCEEDED"))
    #expect(content.components(separatedBy: "\n").count == 2)
  }

  @Test("no commands in the output means no log is written")
  func skipsEmptyOutput() throws {
    let derivedData = FileManager.default.temporaryDirectory
      .appendingPathComponent("dd-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: derivedData) }

    let logURL = try HotReloadBuildLogSynthesizer.writeSyntheticLog(
      buildOutput: Data("** BUILD SUCCEEDED ** (nothing recompiled)".utf8),
      derivedDataPath: derivedData.path
    )
    #expect(logURL == nil)
    #expect(!FileManager.default.fileExists(
      atPath: derivedData.appendingPathComponent("Logs/Build").path))
  }
}
