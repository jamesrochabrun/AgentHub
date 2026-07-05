//
//  WebPreviewSemanticDirectWriteTests.swift
//  AgentHubTests
//
//  End-to-end coverage of the deterministic semantic write path: the
//  coordinator plans each edit against the on-disk source so declared
//  idioms (units, clamp(), tokens) survive, and the page-environment
//  script feeds the unit conversions.
//

import Foundation
import JavaScriptCore
import Testing

@testable import AgentHubCore

private actor SemanticMockFileService: ProjectFileServiceProtocol {
  private var files: [String: String]
  private var writes: [String] = []

  init(files: [String: String]) {
    self.files = files
  }

  func readFile(at path: String, projectPath: String) async throws -> String {
    guard let content = files[path] else {
      throw NSError(domain: "SemanticMockFileService", code: 1)
    }
    return content
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    files[path] = content
    writes.append(content)
  }

  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String] {
    files.keys.sorted()
  }

  func latestWrite() -> String? {
    writes.last
  }

  func writeCount() -> Int {
    writes.count
  }
}

@Suite("Semantic direct writes")
struct WebPreviewSemanticDirectWriteTests {

  @Test("A rem declaration stays rem on disk when the toolbar sends px")
  func remPreservedEndToEnd() async throws {
    let css = ".hero { font-size: 1.05rem; color: #fff; }"
    let path = "/project/styles/site.css"
    let fileService = SemanticMockFileService(files: [path: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "font-size", value: "24px"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )

    let expected = ".hero { font-size: 1.5rem; color: #fff; }"
    #expect(outcome == .written(newSHA256: StylesheetSourceMapper.sha256(of: expected)))
    let written = await fileService.latestWrite()
    #expect(written == expected)
  }

  @Test("clamp() inside an embedded <style> block keeps its structure")
  func clampPreservedInEmbeddedBlock() async throws {
    let html = """
    <html><head>
      <style>.hero { font-size: clamp(17px, 2.2vw, 22px); }</style>
    </head><body><h1 class="hero">Hi</h1></body></html>
    """
    let path = "/project/index.html"
    let fileService = SemanticMockFileService(files: [path: html])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "font-size", value: "19.2px"),
      filePath: path,
      embeddedStyleBlockIndex: 0,
      expectedSHA256: StylesheetSourceMapper.sha256(of: html),
      environment: .fallback,
      projectPath: "/project"
    )

    let expected = html.replacingOccurrences(of: "2.2vw", with: "1.5vw")
    #expect(outcome == .written(newSHA256: StylesheetSourceMapper.sha256(of: expected)))
    let written = await fileService.latestWrite()
    #expect(written == expected)
  }

  @Test("A single-consumer token edit rewrites the token definition, not the usage")
  func tokenDefinitionRewrittenEndToEnd() async throws {
    let css = """
    :root { --hero-size: 60px; }
    h1 { font-size: var(--hero-size); }
    """
    let path = "/project/styles/site.css"
    let fileService = SemanticMockFileService(files: [path: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [1], property: "font-size", value: "48px"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )

    let written = await fileService.latestWrite()
    #expect(written?.contains("--hero-size: 48px;") == true)
    #expect(written?.contains("h1 { font-size: var(--hero-size); }") == true)
    if let written {
      #expect(outcome == .written(newSHA256: StylesheetSourceMapper.sha256(of: written)))
    } else {
      Issue.record("Expected a write to be recorded")
    }
  }

  @Test("A token consumed by another stylesheet detaches instead of rewriting the definition")
  func siblingConsumerBlocksDefinitionRewriteEndToEnd() async throws {
    let css = """
    :root { --hero-size: 60px; }
    h1 { font-size: var(--hero-size); }
    """
    let siblingCSS = ".banner { font-size: var(--hero-size); }"
    let path = "/project/styles/site.css"
    let fileService = SemanticMockFileService(files: [
      path: css,
      "/project/styles/theme.css": siblingCSS,
    ])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [1], property: "font-size", value: "48px"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )

    // Rewriting :root's --hero-size would restyle .banner in theme.css, so
    // only this consumer detaches to a literal — and the outcome carries
    // the detachment so callers can offer a token-wide promotion.
    let written = await fileService.latestWrite()
    #expect(written?.contains("--hero-size: 60px;") == true)
    #expect(written?.contains("h1 { font-size: 48px; }") == true)
    if let written {
      #expect(outcome == .writtenWithTokenDetachment(
        newSHA256: StylesheetSourceMapper.sha256(of: written),
        detachment: CSSTokenDetachment(
          token: "--hero-size",
          projectUsageCount: 2,
          definitionRuleIndexPath: [0],
          appliedLiteral: "48px"
        )
      ))
    } else {
      Issue.record("Expected a write to be recorded")
    }
  }

  @Test("A color edit reattaches to the root token holding that value")
  func tokenReattachedEndToEnd() async throws {
    let css = ":root { --brand: #445566; --muted: #999999; } .cta { color: var(--muted); }"
    let path = "/project/styles/site.css"
    let fileService = SemanticMockFileService(files: [path: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    _ = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [1], property: "color", value: "#445566"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )

    let written = await fileService.latestWrite()
    #expect(written?.contains(".cta { color: var(--brand); }") == true)
    #expect(written?.contains("--brand: #445566;") == true)
  }

  @Test("A detached edit can be promoted to a token-wide update with two proven writes")
  func tokenPromotionRewritesDefinitionAndRestoresUsage() async throws {
    let css = ":root { --fg: rgb(94, 94, 94); } .a { color: var(--fg); } .b { color: var(--fg); }"
    let path = "/project/styles/site.css"
    let fileService = SemanticMockFileService(files: [path: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    // The slider edit detaches .a from the shared token.
    let detachOutcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [1], property: "color", value: "#224466"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )
    guard case .writtenWithTokenDetachment(let detachedSHA, let detachment) = detachOutcome else {
      Issue.record("Expected a detachment outcome, got \(detachOutcome)")
      return
    }
    #expect(detachment.token == "--fg")
    #expect(detachment.definitionRuleIndexPath == [0])

    // Promotion step 1: point the declaration back at the token.
    let restoreOutcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [1], property: "color", value: "var(--fg)"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: detachedSHA,
      environment: .fallback,
      projectPath: "/project"
    )
    let restoredSHA = try #require(restoreOutcome.writtenSHA256)

    // Promotion step 2: rewrite the token's definition with the new value.
    let definitionOutcome = await coordinator.write(
      edit: CSSDeclarationEdit(
        ruleIndexPath: try #require(detachment.definitionRuleIndexPath),
        property: detachment.token,
        value: detachment.appliedLiteral
      ),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: restoredSHA,
      environment: .fallback,
      projectPath: "/project"
    )
    #expect(definitionOutcome.writtenSHA256 != nil)

    // Every consumer now updates through the token; notation is preserved.
    let written = await fileService.latestWrite()
    #expect(written == ":root { --fg: rgb(34, 68, 102); } .a { color: var(--fg); } .b { color: var(--fg); }")
  }

  @Test("A desired value equal to the declared value writes nothing")
  func equivalentValueSkipsWrite() async throws {
    let css = ".hero { font-size: 1.05rem; }"
    let path = "/project/styles/site.css"
    let fileService = SemanticMockFileService(files: [path: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)
    let baseline = StylesheetSourceMapper.sha256(of: css)

    // 1.05rem at a 16px root is exactly 16.8px.
    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "font-size", value: "16.8px"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: baseline,
      environment: .fallback,
      projectPath: "/project"
    )

    #expect(outcome == .written(newSHA256: baseline))
    let writeCount = await fileService.writeCount()
    #expect(writeCount == 0)
  }

  @Test("Viewport-relative units convert against the captured environment")
  func environmentDrivesViewportConversion() async throws {
    let css = ".hero { width: 2vw; }"
    let path = "/project/styles/site.css"
    let fileService = SemanticMockFileService(files: [path: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)
    let environment = WebPreviewPageEnvironment(
      viewportWidth: 960,
      viewportHeight: 700,
      rootFontSize: 16,
      elementFontSize: 16,
      parentFontSize: 16
    )

    _ = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "width", value: "28.8px"),
      filePath: path,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: environment,
      projectPath: "/project"
    )

    let written = await fileService.latestWrite()
    #expect(written == ".hero { width: 3vw; }")
  }
}

@Suite("WebPreviewPageEnvironment")
struct WebPreviewPageEnvironmentTests {

  @Test("The environment script reads viewport and font sizes from the page")
  func scriptCapturesEnvironment() throws {
    let context = try #require(JSContext())
    context.evaluateScript("""
      var window = {
        innerWidth: 1440,
        innerHeight: 900,
        getComputedStyle: function(node) {
          return { fontSize: node && node.fontSize ? node.fontSize : '16px' };
        }
      };
      var document = {
        documentElement: { fontSize: '16px' },
        querySelector: function(selector) {
          return { fontSize: '18px', parentElement: { fontSize: '20px' } };
        }
      };
      """)

    let script = try #require(WebPreviewPageEnvironmentScript.script(selector: ".hero"))
    let result = context.evaluateScript(script)?.toObject()
    #expect(context.exception == nil)

    let environment = try #require(WebPreviewPageEnvironment.parse(result))
    #expect(environment.viewportWidth == 1440)
    #expect(environment.viewportHeight == 900)
    #expect(environment.rootFontSize == 16)
    #expect(environment.elementFontSize == 18)
    #expect(environment.parentFontSize == 20)
  }

  @Test("A missing element falls back to the root font size")
  func scriptFallsBackWithoutElement() throws {
    let context = try #require(JSContext())
    context.evaluateScript("""
      var window = {
        innerWidth: 1280,
        innerHeight: 800,
        getComputedStyle: function(node) { return { fontSize: '16px' }; }
      };
      var document = {
        documentElement: {},
        querySelector: function(selector) { return null; }
      };
      """)

    let script = try #require(WebPreviewPageEnvironmentScript.script(selector: "#missing"))
    let result = context.evaluateScript(script)?.toObject()
    #expect(context.exception == nil)

    let environment = try #require(WebPreviewPageEnvironment.parse(result))
    #expect(environment.elementFontSize == 16)
    #expect(environment.parentFontSize == 16)
  }

  @Test("Parsing rejects payloads without a usable viewport")
  func parseRejectsMissingViewport() {
    #expect(WebPreviewPageEnvironment.parse(["rootFontSize": 16.0]) == nil)
    #expect(WebPreviewPageEnvironment.parse(nil) == nil)
    #expect(WebPreviewPageEnvironment.parse([
      "viewportWidth": 0.0,
      "viewportHeight": 800.0,
      "rootFontSize": 16.0,
    ]) == nil)
  }

  @Test("Parsing defaults element and parent font sizes to the root")
  func parseDefaultsFontSizes() throws {
    let environment = try #require(WebPreviewPageEnvironment.parse([
      "viewportWidth": 1280.0,
      "viewportHeight": 800.0,
      "rootFontSize": 18.0,
    ]))
    #expect(environment.elementFontSize == 18)
    #expect(environment.parentFontSize == 18)
  }
}
