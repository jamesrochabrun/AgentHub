import AgentHubCLIKit
import Foundation

@testable import AgentHubCore

func makeStudioCanvas(
  id: String = "canvas-1",
  title: String = "Primary button",
  createdAt: Date = Date(timeIntervalSince1970: 1_000),
  revision: Int = 1,
  sourcePath: String? = "src/Button.tsx",
  variants: [StudioVariant] = [
    StudioVariant(name: "solid", html: "<button class=\"btn\">Go</button>", css: ".btn { color: red; }", notes: "default"),
    StudioVariant(name: "ghost", html: "<button class=\"btn\">Go</button>", css: ".btn { color: blue; }", width: 320, height: 120),
  ],
  warnings: [String] = [],
  provider: WorktreeLaunchProvider = .claude,
  sessionId: String? = "session-1",
  projectPath: String? = "/tmp/project",
  processId: Int32 = 42
) -> StudioArtifact {
  StudioArtifact(
    id: id,
    kind: .canvas,
    createdAt: createdAt,
    revision: revision,
    title: title,
    sourcePath: sourcePath,
    variants: variants,
    warnings: warnings,
    sourceProvider: provider,
    sourceSessionId: sessionId,
    sourceProjectPath: projectPath,
    sourceProcessId: processId
  )
}

func makeStudioDocument(
  id: String = "doc-1",
  title: String = "Q3 report",
  html: String = "<!DOCTYPE html><html><head><title>R</title></head><body><h1>Report</h1></body></html>",
  createdAt: Date = Date(timeIntervalSince1970: 1_000),
  provider: WorktreeLaunchProvider = .codex,
  sessionId: String? = "session-2",
  projectPath: String? = "/tmp/project"
) -> StudioArtifact {
  StudioArtifact(
    id: id,
    kind: .document,
    createdAt: createdAt,
    title: title,
    html: html,
    sourceProvider: provider,
    sourceSessionId: sessionId,
    sourceProjectPath: projectPath,
    sourceProcessId: 7
  )
}

func temporaryStudioRoot() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-studio-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
