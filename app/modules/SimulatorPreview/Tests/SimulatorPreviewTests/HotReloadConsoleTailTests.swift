import Foundation
import Testing

@testable import SimulatorPreview

@Suite("HotReloadConsoleTail")
@MainActor
struct HotReloadConsoleTailTests {

  private func tempPath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("console-\(UUID().uuidString).log").path
  }

  private func waitUntil(
    timeout: TimeInterval = 2, condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  @Test("delivers complete lines incrementally, holding partial lines")
  func incrementalLines() async throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let tail = HotReloadConsoleTail()
    defer { tail.stop() }

    let collected = Collected()
    tail.start(path: path) { collected.lines.append($0) }

    let handle = FileHandle(forWritingAtPath: path)!
    defer { try? handle.close() }
    try handle.write(contentsOf: Data("🔥 line one\npartial".utf8))
    await waitUntil { collected.lines.count == 1 }
    #expect(collected.lines == ["🔥 line one"])

    try handle.write(contentsOf: Data(" continues\n".utf8))
    await waitUntil { collected.lines.count == 2 }
    #expect(collected.lines == ["🔥 line one", "partial continues"])
  }

  @Test("handles truncation when simctl restarts the log")
  func truncation() async throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let tail = HotReloadConsoleTail()
    defer { tail.stop() }

    let collected = Collected()
    tail.start(path: path) { collected.lines.append($0) }

    try Data("first launch with its engine banner\n".utf8)
      .write(to: URL(fileURLWithPath: path))
    await waitUntil { collected.lines.count == 1 }

    // New launch truncates and rewrites the file. (Detection is size-based,
    // so the controller also restarts the tail after each rebuild relaunch —
    // this covers the in-between window.)
    try Data("second\n".utf8).write(to: URL(fileURLWithPath: path))
    await waitUntil { collected.lines.count == 2 }
    #expect(collected.lines == ["first launch with its engine banner", "second"])
  }

  @MainActor
  private final class Collected {
    var lines: [String] = []
  }
}
