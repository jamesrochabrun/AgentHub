import AgentHubCLIKit
import Canvas
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Studio tweaks")
struct StudioTweaksTests {
  private let props = [
    StudioTweakProp(name: "radius", label: "Corner radius", type: .slider, value: .number(12), minimum: 0, maximum: 32, step: 1, unit: "px"),
    StudioTweakProp(name: "accent", type: .color, value: .string("#0a84ff")),
    StudioTweakProp(name: "cta", type: .text, value: .string("Continue</script>")),
    StudioTweakProp(name: "shadow", type: .toggle, value: .boolean(true)),
  ]

  @Test("The canvas host page exposes props as CSS variables and declares the schema")
  func hostPageExposesProps() throws {
    let artifact = makeStudioCanvas().withContent(props: props)
    let html = try StudioDocumentWriter.render(artifact)

    #expect(html.contains("<style id=\"studio-props\">"))
    #expect(html.contains("  --radius: 12px;"))
    #expect(html.contains("  --accent: #0a84ff;"))
    #expect(html.contains("  --shadow: 1;"))
    #expect(html.contains("window.__studioProps = ["))
    #expect(html.contains("\"name\":\"radius\""))
    #expect(html.contains("\"unit\":\"px\""))
    #expect(html.contains("\"label\":\"Corner radius\""))
    // A closing tag inside a value must terminate neither the host <script>
    // (JSON escape) nor the props <style> block (CSS hex escape).
    #expect(!html.contains("Continue</script>"))
    #expect(html.contains("Continue<\\/script>"))
    #expect(html.contains("--cta: Continue\\3c /script\\3e ;"))
    #expect(StudioDocumentWriter.cssBlockValue("a } b; </style>") == "a \\7d  b\\3b  \\3c /style\\3e ")
    #expect(html.contains("window.dc_set_props(schema)"))
    #expect(html.contains("window.dc_on_props_changed = function"))
  }

  @Test("A canvas without props emits no props block and an empty schema")
  func hostPageWithoutProps() throws {
    let html = try StudioDocumentWriter.render(makeStudioCanvas())
    #expect(!html.contains("studio-props"))
    #expect(html.contains("window.__studioProps = [];"))
  }

  @MainActor
  @Test("Save defaults on a canvas updates the shared schema and re-stores with a revision bump")
  func saveDefaultsCanvas() async throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = StudioPersistenceMock()
    let library = StudioLibrary(
      persistence: persistence,
      documents: StudioDocumentWriter(rootURL: root.appendingPathComponent("docs")),
      server: StudioServerMock(),
      index: StudioIndexStore(directoryURL: root.appendingPathComponent("index"))
    )
    await library.store(makeStudioCanvas(id: "c1").withContent(props: props), projectKey: "/repo", sessionId: "s1", aliasPaths: [])

    try await library.saveTweakDefaults(
      artifactId: "c1",
      values: ["radius": .number(20), "shadow": .boolean(false)],
      projectKey: "/repo",
      sessionId: "s1",
      aliasPaths: []
    )

    let stored = try #require(library.artifact(id: "c1", projectKey: "/repo"))
    #expect(stored.revision == 2)
    #expect(stored.props.first { $0.name == "radius" }?.value == .number(20))
    #expect(stored.props.first { $0.name == "shadow" }?.value == .boolean(false))
    #expect(stored.props.first { $0.name == "accent" }?.value == .string("#0a84ff"))
    #expect(stored.variants == makeStudioCanvas().variants)
    let html = try String(contentsOf: library.documentURL(for: stored, projectKey: "/repo"), encoding: .utf8)
    #expect(html.contains("--radius: 20px;"))
    #expect(try persistence.saved.first?.decodedArtifact().props.first { $0.name == "radius" }?.value == .number(20))

    await #expect(throws: StudioLibrary.TweakDefaultsError.self) {
      try await library.saveTweakDefaults(artifactId: "c1", values: ["nope": .number(1)], projectKey: "/repo", sessionId: "s1", aliasPaths: [])
    }
  }

  @MainActor
  @Test("Save defaults on a document splices the dc_set_props call, never the whole file")
  func saveDefaultsDocument() async throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StudioLibrary(
      persistence: StudioPersistenceMock(),
      documents: StudioDocumentWriter(rootURL: root.appendingPathComponent("docs")),
      server: StudioServerMock(),
      index: StudioIndexStore(directoryURL: root.appendingPathComponent("index"))
    )
    let html = """
      <!DOCTYPE html><html><body><h1 id="t">Hi</h1>
      <script>
      if (window.dc_set_props) dc_set_props({ radius: { type: "slider", value: 12, min: 0, max: 40 }, accent: { type: "color", value: "#0a84ff" } });
      </script></body></html>
      """
    await library.store(makeStudioDocument(id: "d1", html: html), projectKey: "/repo", sessionId: "s1", aliasPaths: [])

    try await library.saveTweakDefaults(artifactId: "d1", values: ["radius": .number(24)], projectKey: "/repo", sessionId: "s1", aliasPaths: [])

    let stored = try #require(library.artifact(id: "d1", projectKey: "/repo"))
    #expect(stored.revision == 2)
    #expect(stored.html?.contains("radius: { type: \"slider\", value: 24, min: 0, max: 40 }") == true)
    #expect(stored.html?.contains("accent: { type: \"color\", value: \"#0a84ff\" }") == true)
    #expect(stored.html?.hasPrefix("<!DOCTYPE html><html><body><h1 id=\"t\">Hi</h1>") == true)
  }

  @Test("Tweaks prompts re-file by id and forbid project edits")
  func prompts() {
    let canvas = makeStudioCanvas(id: "c9")
    let existing = [TweakProp(name: "radius", label: "Radius", type: .slider, value: .number(12))]
    let ideas = StudioTweaksPromptBuilder.ideasPrompt(artifact: canvas, existingProps: existing)
    #expect(ideas.contains("design canvas \"Primary button\" (id c9)"))
    #expect(ideas.contains("radius (slider)"))
    #expect(ideas.contains("agenthub_design using id c9"))
    #expect(ideas.contains("var(--<name>)"))
    #expect(ideas.contains("do not edit project files"))

    let custom = StudioTweaksPromptBuilder.customPrompt(artifact: makeStudioDocument(id: "d9"), instruction: "a density knob")
    #expect(custom.contains("artifact \"Q3 report\" (id d9): a density knob"))
    #expect(custom.contains("agenthub_artifact using id d9"))
    #expect(custom.contains("dc_set_props"))

    let delete = StudioTweaksPromptBuilder.deleteAllPrompt(artifact: canvas)
    #expect(delete.contains("with no `props`"))
    #expect(delete.contains("do not edit project files"))
  }
}
