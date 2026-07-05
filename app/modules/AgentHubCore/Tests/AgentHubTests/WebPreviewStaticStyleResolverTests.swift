import Foundation
import Testing
import WebKit

@testable import AgentHubCore

// MARK: - HTMLStylesheetScanner

@Suite("HTMLStylesheetScanner")
struct HTMLStylesheetScannerTests {

  @Test("Extracts links and style blocks in document order")
  func extractsSourcesInOrder() {
    let html = """
    <html><head>
      <link rel="icon" href="favicon.ico">
      <link rel="stylesheet" href="styles/site.css">
      <style>
        .hero { color: red; }
      </style>
      <link rel="stylesheet" href="theme.css" media="(prefers-color-scheme: dark)">
      <style media="print">.a { display: none; }</style>
    </head><body></body></html>
    """

    let sources = HTMLStylesheetScanner.stylesheetSources(in: html)

    #expect(sources.count == 4)
    #expect(sources[0] == .linked(href: "styles/site.css", media: nil))
    guard case .inlineBlock(_, let firstOrdinal, nil) = sources[1] else {
      Issue.record("Expected inline block, got \(sources[1])")
      return
    }
    #expect(firstOrdinal == 0)
    #expect(sources[2] == .linked(href: "theme.css", media: "(prefers-color-scheme: dark)"))
    guard case .inlineBlock(_, let secondOrdinal, let media) = sources[3] else {
      Issue.record("Expected inline block, got \(sources[3])")
      return
    }
    #expect(secondOrdinal == 1)
    #expect(media == "print")
  }

  @Test("Inline block content is addressable by ordinal")
  func inlineBlockContentByOrdinal() {
    let html = "<style>.a { color: red; }</style><p>x</p><style>.b { color: blue; }</style>"

    let second = HTMLStylesheetScanner.inlineBlockContent(ordinal: 1, in: html)

    #expect(second?.content == ".b { color: blue; }")
    #expect(HTMLStylesheetScanner.inlineBlockContent(ordinal: 2, in: html) == nil)
  }
}

// MARK: - CSSSelectorSpecificity

@Suite("CSSSelectorSpecificity")
struct CSSSelectorSpecificityTests {

  @Test("Computes id/class/type counts")
  func computesCounts() {
    #expect(CSSSelectorSpecificity.compute("#nav .item a") == [1, 1, 1])
    #expect(CSSSelectorSpecificity.compute("button.cta:hover") == [0, 2, 1])
    #expect(CSSSelectorSpecificity.compute("ul > li::before") == [0, 0, 3])
    #expect(CSSSelectorSpecificity.compute("[data-role=\"x\"].active") == [0, 2, 0])
  }

  @Test("Flags functional pseudo-classes and splits selector lists")
  func flagsAndSplits() {
    #expect(CSSSelectorSpecificity.hasComplexPseudo(".a:not(.b)"))
    #expect(!CSSSelectorSpecificity.hasComplexPseudo(".a:hover"))
    #expect(CSSSelectorSpecificity.selectorParts(".a, .b:is(x, y), .c") == [".a", ".b:is(x, y)", ".c"])
  }
}

// MARK: - Winner computation

private func makeCandidate(
  source: StaticStyleRuleCandidate.Source = .linkedFile(path: "/project/site.css"),
  ruleIndexPath: [Int] = [0],
  selectorParts: [String],
  mediaConditionIndices: [Int] = [],
  isFlagged: Bool = false,
  declarations: [StaticStyleDeclaration]
) -> StaticStyleRuleCandidate {
  StaticStyleRuleCandidate(
    source: source,
    ruleIndexPath: ruleIndexPath,
    selectorParts: selectorParts,
    mediaConditionIndices: mediaConditionIndices,
    supportsConditionIndices: [],
    isFlagged: isFlagged,
    declarations: declarations
  )
}

@Suite("StaticStyleWinnerComputation")
struct StaticStyleWinnerComputationTests {

  @Test("Specificity beats source order; source order breaks ties")
  func specificityAndOrder() {
    let candidates = [
      makeCandidate(
        ruleIndexPath: [0],
        selectorParts: ["button"],
        declarations: [StaticStyleDeclaration(name: "color", value: "red", isImportant: false)]
      ),
      makeCandidate(
        ruleIndexPath: [1],
        selectorParts: [".cta"],
        declarations: [StaticStyleDeclaration(name: "color", value: "blue", isImportant: false)]
      ),
      makeCandidate(
        ruleIndexPath: [2],
        selectorParts: ["button"],
        declarations: [StaticStyleDeclaration(name: "line-height", value: "20px", isImportant: false)]
      ),
    ]
    let selectorIndex = ["button": 0, ".cta": 1]
    let verdicts = WebPreviewStaticMatchVerdicts(
      selectorMatches: [true, true],
      mediaMatches: [],
      supportsMatches: [],
      inlineStyles: [:]
    )

    let winners = WebPreviewStaticStyleResolver.computeWinners(
      candidates: candidates,
      selectorIndex: selectorIndex,
      verdicts: verdicts,
      properties: ["color", "line-height"]
    )

    #expect(winners["color"]?.ruleIndexPath == [1])
    #expect(winners["line-height"]?.ruleIndexPath == [2])
  }

  @Test("Important declarations win over higher specificity")
  func importanceWins() {
    let candidates = [
      makeCandidate(
        ruleIndexPath: [0],
        selectorParts: ["button"],
        declarations: [StaticStyleDeclaration(name: "color", value: "red", isImportant: true)]
      ),
      makeCandidate(
        ruleIndexPath: [1],
        selectorParts: ["#hero .cta"],
        declarations: [StaticStyleDeclaration(name: "color", value: "blue", isImportant: false)]
      ),
    ]
    let selectorIndex = ["button": 0, "#hero .cta": 1]
    let verdicts = WebPreviewStaticMatchVerdicts(
      selectorMatches: [true, true],
      mediaMatches: [],
      supportsMatches: [],
      inlineStyles: [:]
    )

    let winners = WebPreviewStaticStyleResolver.computeWinners(
      candidates: candidates,
      selectorIndex: selectorIndex,
      verdicts: verdicts,
      properties: ["color"]
    )

    #expect(winners["color"]?.ruleIndexPath == [0])
  }

  @Test("Non-matching media conditions exclude the rule")
  func mediaConditionsFilter() {
    let candidates = [
      makeCandidate(
        ruleIndexPath: [0],
        selectorParts: [".cta"],
        declarations: [StaticStyleDeclaration(name: "color", value: "red", isImportant: false)]
      ),
      makeCandidate(
        ruleIndexPath: [1, 0],
        selectorParts: [".cta"],
        mediaConditionIndices: [0],
        declarations: [StaticStyleDeclaration(name: "color", value: "blue", isImportant: false)]
      ),
    ]
    let verdicts = WebPreviewStaticMatchVerdicts(
      selectorMatches: [true],
      mediaMatches: [false],
      supportsMatches: [],
      inlineStyles: [:]
    )

    let winners = WebPreviewStaticStyleResolver.computeWinners(
      candidates: candidates,
      selectorIndex: [".cta": 0],
      verdicts: verdicts,
      properties: ["color"]
    )

    #expect(winners["color"]?.ruleIndexPath == [0])
  }

  @Test("Flagged winners and inline-style overrides yield no direct target")
  func flaggedAndInlineYieldNothing() {
    let flagged = [
      makeCandidate(
        selectorParts: [".cta"],
        isFlagged: true,
        declarations: [StaticStyleDeclaration(name: "color", value: "red", isImportant: false)]
      )
    ]
    let verdicts = WebPreviewStaticMatchVerdicts(
      selectorMatches: [true],
      mediaMatches: [],
      supportsMatches: [],
      inlineStyles: [:]
    )
    #expect(WebPreviewStaticStyleResolver.computeWinners(
      candidates: flagged,
      selectorIndex: [".cta": 0],
      verdicts: verdicts,
      properties: ["color"]
    ).isEmpty)

    let plain = [
      makeCandidate(
        selectorParts: [".cta"],
        declarations: [StaticStyleDeclaration(name: "color", value: "red", isImportant: false)]
      )
    ]
    let inlineVerdicts = WebPreviewStaticMatchVerdicts(
      selectorMatches: [true],
      mediaMatches: [],
      supportsMatches: [],
      inlineStyles: ["color": "green"]
    )
    #expect(WebPreviewStaticStyleResolver.computeWinners(
      candidates: plain,
      selectorIndex: [".cta": 0],
      verdicts: inlineVerdicts,
      properties: ["color"]
    ).isEmpty)
  }
}

// MARK: - Resolver end-to-end (mocked probe, real files)

@MainActor
private final class MockStaticProbe: WebPreviewStaticMatchProbing {
  var verdictsBySelectorCount: (Int, Int, Int) -> WebPreviewStaticMatchVerdicts

  init(verdictsBySelectorCount: @escaping (Int, Int, Int) -> WebPreviewStaticMatchVerdicts) {
    self.verdictsBySelectorCount = verdictsBySelectorCount
  }

  private(set) var probedSelectors: [String] = []

  func probe(
    selector: String,
    candidateSelectors: [String],
    mediaConditions: [String],
    supportsConditions: [String],
    properties: [String],
    in webView: WKWebView
  ) async -> WebPreviewStaticMatchVerdicts? {
    probedSelectors = candidateSelectors
    return verdictsBySelectorCount(candidateSelectors.count, mediaConditions.count, supportsConditions.count)
  }
}

@MainActor
@Suite("WebPreviewStaticStyleResolver")
struct WebPreviewStaticStyleResolverTests {

  @Test("Resolves direct targets for linked stylesheets and inline blocks")
  func resolvesLinkedAndInlineTargets() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("StaticResolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectPath = root.standardizedFileURL.resolvingSymlinksInPath().path

    let css = """
    .cta { line-height: 26px; }
    """
    let html = """
    <html><head>
      <link rel="stylesheet" href="site.css">
      <style>.cta { color: red; }</style>
    </head><body><button class="cta">Go</button></body></html>
    """
    let cssPath = projectPath + "/site.css"
    let htmlPath = projectPath + "/index.html"
    try css.write(toFile: cssPath, atomically: true, encoding: .utf8)
    try html.write(toFile: htmlPath, atomically: true, encoding: .utf8)

    // Every file-derived selector matches (they are all ".cta").
    let probe = MockStaticProbe { selectorCount, mediaCount, supportsCount in
      WebPreviewStaticMatchVerdicts(
        selectorMatches: Array(repeating: true, count: selectorCount),
        mediaMatches: Array(repeating: true, count: mediaCount),
        supportsMatches: Array(repeating: true, count: supportsCount),
        inlineStyles: [:]
      )
    }
    let resolver = WebPreviewStaticStyleResolver(
      fileService: ProjectFileService.shared,
      probe: probe
    )

    let targets = await resolver.resolveDirectTargets(
      elementSelector: ".cta",
      servedFilePath: htmlPath,
      projectPath: projectPath,
      properties: ["line-height", "color", "padding"],
      in: WKWebView()
    )

    #expect(targets["line-height"] == WebPreviewDirectStyleTarget(
      filePath: cssPath,
      ruleIndexPath: [0],
      contentSHA256: StylesheetSourceMapper.sha256(of: css),
      embeddedStyleBlockIndex: nil
    ))
    #expect(targets["color"] == WebPreviewDirectStyleTarget(
      filePath: htmlPath,
      ruleIndexPath: [0],
      contentSHA256: StylesheetSourceMapper.sha256(of: html),
      embeddedStyleBlockIndex: 0
    ))
    // `padding` is declared by no matching rule, so it inserts into the
    // element's plainest matching anchor (the inline `.cta` block wins the
    // source-order tie against site.css's `.cta`).
    #expect(targets["padding"] == WebPreviewDirectStyleTarget(
      filePath: htmlPath,
      ruleIndexPath: [0],
      contentSHA256: StylesheetSourceMapper.sha256(of: html),
      embeddedStyleBlockIndex: 0
    ))
  }
}

// MARK: - Embedded inline-block writes

private actor EmbeddedMockFileService: ProjectFileServiceProtocol {
  private var files: [String: String]
  private(set) var writtenContent: String?

  init(files: [String: String]) {
    self.files = files
  }

  func readFile(at path: String, projectPath: String) async throws -> String {
    guard let content = files[path] else { throw CocoaError(.fileNoSuchFile) }
    return content
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    files[path] = content
    writtenContent = content
  }

  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String] {
    files.keys.sorted()
  }

  func latestWrite() -> String? {
    writtenContent
  }
}

@Suite("WebPreviewDirectCSSWriteCoordinator embedded blocks")
struct WebPreviewDirectCSSWriteEmbeddedTests {

  @Test("Edits inside an inline <style> block splice only that declaration")
  func editsInsideInlineBlock() async throws {
    let html = """
    <html><head>
      <style>.hero { font-size: 40px; }</style>
      <style>.cta { color: red; padding: 4px; }</style>
    </head><body><p class="cta">x</p></body></html>
    """
    let path = "/project/index.html"
    let fileService = EmbeddedMockFileService(files: [path: html])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "blue"),
      filePath: path,
      embeddedStyleBlockIndex: 1,
      expectedSHA256: StylesheetSourceMapper.sha256(of: html),
      environment: .fallback,
      projectPath: "/project"
    )

    let expected = html.replacingOccurrences(of: "color: red;", with: "color: blue;")
    #expect(outcome == .written(newSHA256: StylesheetSourceMapper.sha256(of: expected)))
    let written = await fileService.latestWrite()
    #expect(written == expected)
  }

  @Test("A missing block ordinal fails without writing")
  func missingBlockOrdinalFails() async throws {
    let html = "<html><head><style>.a { color: red; }</style></head></html>"
    let path = "/project/index.html"
    let fileService = EmbeddedMockFileService(files: [path: html])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "blue"),
      filePath: path,
      embeddedStyleBlockIndex: 3,
      expectedSHA256: StylesheetSourceMapper.sha256(of: html),
      environment: .fallback,
      projectPath: "/project"
    )

    guard case .editFailed = outcome else {
      Issue.record("Expected editFailed, got \(outcome)")
      return
    }
    let written = await fileService.latestWrite()
    #expect(written == nil)
  }
}
