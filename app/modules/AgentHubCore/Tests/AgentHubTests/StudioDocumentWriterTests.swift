import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@Suite("StudioDocumentWriter")
struct StudioDocumentWriterTests {
  @Test("A document artifact is served verbatim")
  func documentIsVerbatim() throws {
    let artifact = makeStudioDocument(html: "<!DOCTYPE html><html><body><p>hi</p></body></html>")
    #expect(try StudioDocumentWriter.render(artifact) == "<!DOCTYPE html><html><body><p>hi</p></body></html>")
  }

  @Test("A canvas renders one labelled artboard per variant, in order, with scoped CSS")
  func canvasRendersArtboards() throws {
    let html = try StudioDocumentWriter.render(makeStudioCanvas())

    #expect(html.contains("<title>Primary button</title>"))
    let solidRange = try #require(html.range(of: "class=\"studio-artboard\" data-variant=\"solid\""))
    let ghostRange = try #require(html.range(of: "class=\"studio-artboard\" data-variant=\"ghost\""))
    #expect(solidRange.lowerBound < ghostRange.lowerBound)
    #expect(html.contains("<span class=\"studio-name\">solid</span>"))
    #expect(html.contains("<p class=\"studio-notes\">default</p>"))
    #expect(html.contains(".studio-artboard[data-variant=\"solid\"] .btn {\n  color: red;\n}"))
    #expect(html.contains(".studio-artboard[data-variant=\"ghost\"] .btn {\n  color: blue;\n}"))
    #expect(html.contains(".studio-artboard[data-variant=\"ghost\"] { width: 320px; height: 120px; overflow: auto; }"))
    #expect(html.contains("window.__agenthubStudio"))
    // Pan/zoom is a transform, not a scroll: the host must tell the inspector
    // the viewport moved or the comment box stays behind.
    #expect(html.contains("window.dispatchEvent(new Event('scroll'))"))
    #expect(html.range(of: "label.textContent = Math.round\\(scale \\* 100\\) \\+ '%';\\s*notifyViewportMoved\\(\\);", options: .regularExpression) != nil)
    // The host owns the document: exactly one <html> and no nested documents.
    #expect(html.components(separatedBy: "<html").count == 2)
  }

  @Test("Variant names and notes are HTML-escaped in the host chrome")
  func namesAreEscaped() throws {
    let artifact = makeStudioCanvas(variants: [
      StudioVariant(name: "a<b>", html: "<i>x</i>", css: "", notes: "use \"quotes\" & <tags>")
    ])
    let html = try StudioDocumentWriter.render(artifact)
    #expect(html.contains("data-variant=\"a&lt;b&gt;\""))
    #expect(html.contains("use &quot;quotes&quot; &amp; &lt;tags&gt;"))
    #expect(!html.contains("<p class=\"studio-notes\">use \"quotes\""))
  }

  @Test("Unscopable variant CSS makes render throw rather than leak")
  func unscopableCSSThrows() {
    let artifact = makeStudioCanvas(variants: [StudioVariant(name: "x", html: "<i>x</i>", css: ".a { color: red;")])
    #expect(throws: StudioCSSScoper.ParseError.self) {
      try StudioDocumentWriter.render(artifact)
    }
  }

  @Test("The canvas host page carries an Implement button per artboard and the edit-bake helpers")
  func hostPageImplementAndBakeHelpers() throws {
    let html = try StudioDocumentWriter.render(makeStudioCanvas())
    #expect(html.contains("<button type=\"button\" class=\"studio-implement\" data-variant=\"solid\""))
    #expect(html.contains("<button type=\"button\" class=\"studio-implement\" data-variant=\"ghost\""))
    #expect(html.contains("messageHandlers.agentHubStudio"))
    #expect(html.contains("postMessage({ type: 'implement', variant:"))
    #expect(html.contains("serializeArtboards: function"))
    #expect(html.contains("variantsForSelectors: function"))
    #expect(html.contains("removeElement: function"))
    // Hidden unless the AgentHub bridge is present (plain browser / export).
    #expect(html.contains("body.studio-hosted .studio-implement { display: inline-block; }"))
  }

  @Test("Writing an artifact also writes the payload sidecar the CLI reads")
  func writesPayloadSidecar() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = StudioDocumentWriter(rootURL: root)
    let artifact = makeStudioCanvas(id: "canvas-1")

    let url = try writer.write(artifact, projectKey: "/tmp/project")
    let payloadURL = StudioDocumentWriter.payloadURL(besideDocument: url)
    #expect(payloadURL.lastPathComponent == "artifact.json")
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(StudioArtifact.self, from: Data(contentsOf: payloadURL)) == artifact)
  }

  @Test("Writes under root/{project}/{id}/index.html and deletes cascade")
  func writesAndDeletes() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = StudioDocumentWriter(rootURL: root)

    let url = try writer.write(makeStudioCanvas(id: "canvas-1"), projectKey: "/tmp/project")
    #expect(url.lastPathComponent == "index.html")
    #expect(url.deletingLastPathComponent().lastPathComponent == "canvas-1")
    #expect(url.path.hasPrefix(root.path))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(writer.relativePath(forArtifactId: "canvas-1", projectKey: "/tmp/project").hasSuffix("/canvas-1/index.html"))

    // Same key, trailing slash or not, lands in the same project directory.
    #expect(
      writer.documentURL(forArtifactId: "canvas-1", projectKey: "/tmp/project/")
        == writer.documentURL(forArtifactId: "canvas-1", projectKey: "/tmp/project")
    )

    try writer.delete(artifactId: "canvas-1", projectKey: "/tmp/project")
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

    _ = try writer.write(makeStudioCanvas(id: "canvas-2"), projectKey: "/tmp/project")
    try writer.deleteAll(projectKey: "/tmp/project")
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().deletingLastPathComponent().path))
  }

  @Test("A canvas written by an older host page is stale; documents are current whenever present")
  func hostVersionStaleness() throws {
    let root = try temporaryStudioRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = StudioDocumentWriter(rootURL: root)
    let canvas = makeStudioCanvas(id: "c1")
    let document = makeStudioDocument(id: "d1")

    #expect(!writer.isCurrent(canvas, projectKey: "/p"))
    let url = try writer.write(canvas, projectKey: "/p")
    #expect(writer.isCurrent(canvas, projectKey: "/p"))
    #expect(try String(contentsOf: url, encoding: .utf8).contains("<meta name=\"agenthub-studio-host\" content=\"\(StudioDocumentWriter.hostVersion)\">"))

    // Simulate a file from an older writer.
    try Data("<!DOCTYPE html><html><head><meta name=\"agenthub-studio-host\" content=\"1\"></head><body></body></html>".utf8).write(to: url)
    #expect(!writer.isCurrent(canvas, projectKey: "/p"))
    try Data("<!DOCTYPE html><html><body>no marker</body></html>".utf8).write(to: url)
    #expect(!writer.isCurrent(canvas, projectKey: "/p"))

    #expect(!writer.isCurrent(document, projectKey: "/p"))
    _ = try writer.write(document, projectKey: "/p")
    #expect(writer.isCurrent(document, projectKey: "/p"))
  }

  @Test("Unsafe ids never reach the filesystem as path components")
  func unsafeIdsAreHashed() {
    #expect(StudioDocumentWriter.artifactDirectoryName(forId: "canvas-1") == "canvas-1")
    #expect(StudioDocumentWriter.artifactDirectoryName(forId: "A1B2-c3_d.4") == "A1B2-c3_d.4")
    for unsafe in ["..", ".", "../etc/passwd", "a/b", "", String(repeating: "x", count: 81), "sp ace", "..hidden"] {
      let name = StudioDocumentWriter.artifactDirectoryName(forId: unsafe)
      #expect(name.hasPrefix("h-"), "\(unsafe) should hash, got \(name)")
      #expect(!name.contains("/"))
    }
    #expect(StudioDocumentWriter.artifactDirectoryName(forId: "..hidden").hasPrefix("h-"))
  }
}
