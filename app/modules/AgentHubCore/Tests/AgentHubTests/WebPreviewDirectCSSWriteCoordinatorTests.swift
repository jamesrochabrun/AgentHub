import Foundation
import Testing

@testable import AgentHubCore

private actor MockFileService: ProjectFileServiceProtocol {
  struct WriteCall: Equatable, Sendable {
    let path: String
    let content: String
  }

  enum MockError: Error {
    case missingFile
  }

  private var files: [String: String]
  private var writes: [WriteCall] = []

  init(files: [String: String]) {
    self.files = files
  }

  func readFile(at path: String, projectPath: String) async throws -> String {
    guard let content = files[path] else { throw MockError.missingFile }
    return content
  }

  func writeFile(at path: String, content: String, projectPath: String) async throws {
    files[path] = content
    writes.append(WriteCall(path: path, content: content))
  }

  func listTextFiles(in projectPath: String, extensions: Set<String>) async -> [String] {
    files.keys.sorted()
  }

  func recordedWrites() -> [WriteCall] {
    writes
  }
}

@Suite("WebPreviewDirectCSSWriteCoordinator")
struct WebPreviewDirectCSSWriteCoordinatorTests {
  private let filePath = "/project/styles/site.css"
  private let css = """
  .cta {
    line-height: 26px;
  }
  """

  @Test("A matching baseline writes the spliced edit and returns the new hash")
  func matchingBaselineWrites() async throws {
    let fileService = MockFileService(files: [filePath: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "line-height", value: "30px"),
      filePath: filePath,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )

    let expectedContent = css.replacingOccurrences(of: "26px", with: "30px")
    #expect(outcome == .written(newSHA256: StylesheetSourceMapper.sha256(of: expectedContent)))
    let writes = await fileService.recordedWrites()
    #expect(writes == [.init(path: filePath, content: expectedContent)])
  }

  @Test("A drifted baseline never writes")
  func driftedBaselineNeverWrites() async throws {
    let fileService = MockFileService(files: [filePath: css + "\n/* concurrent agent edit */"])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "line-height", value: "30px"),
      filePath: filePath,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )

    #expect(outcome == .baselineDrift)
    let writes = await fileService.recordedWrites()
    #expect(writes.isEmpty)
  }

  @Test("A failing edit (unknown rule) never writes")
  func failingEditNeverWrites() async throws {
    let fileService = MockFileService(files: [filePath: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [7], property: "line-height", value: "30px"),
      filePath: filePath,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: StylesheetSourceMapper.sha256(of: css),
      environment: .fallback,
      projectPath: "/project"
    )

    guard case .editFailed = outcome else {
      Issue.record("Expected editFailed, got \(outcome)")
      return
    }
    let writes = await fileService.recordedWrites()
    #expect(writes.isEmpty)
  }

  @Test("A no-op edit reports written without touching the file")
  func noOpEditSkipsWrite() async throws {
    let fileService = MockFileService(files: [filePath: css])
    let coordinator = WebPreviewDirectCSSWriteCoordinator(fileService: fileService)

    let baseline = StylesheetSourceMapper.sha256(of: css)
    let outcome = await coordinator.write(
      edit: CSSDeclarationEdit(ruleIndexPath: [0], property: "padding", value: nil),
      filePath: filePath,
      embeddedStyleBlockIndex: nil,
      expectedSHA256: baseline,
      environment: .fallback,
      projectPath: "/project"
    )

    #expect(outcome == .written(newSHA256: baseline))
    let writes = await fileService.recordedWrites()
    #expect(writes.isEmpty)
  }
}
