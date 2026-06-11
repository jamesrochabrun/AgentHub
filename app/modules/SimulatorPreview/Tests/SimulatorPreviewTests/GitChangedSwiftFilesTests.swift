import Testing

@testable import SimulatorPreview

@Suite("GitChangedSwiftFiles")
struct GitChangedSwiftFilesTests {

  @Test("parses porcelain output into Swift basenames, in order")
  func parsesPorcelain() {
    let porcelain = """
     M MathGame/Views/HomeView.swift
    ?? MathGame/Views/NewView.swift
    A  Assets/icon.png
     M README.md
    R  Old/Name.swift -> MathGame/Renamed.swift
     M "Spaced Dir/With Space.swift"
     M MathGame/Views/HomeView.swift
    """
    #expect(GitChangedSwiftFiles.parse(porcelain: porcelain) == [
      "HomeView.swift", "NewView.swift", "Renamed.swift", "With Space.swift",
    ])
  }

  @Test("empty and garbage input parse to nothing")
  func emptyInput() {
    #expect(GitChangedSwiftFiles.parse(porcelain: "").isEmpty)
    #expect(GitChangedSwiftFiles.parse(porcelain: "x\n\n??").isEmpty)
  }
}
