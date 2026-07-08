import Testing

@testable import AgentHubCore

@Suite("Simulator preview spotlight candidates")
struct SimulatorPreviewSpotlightCandidateTests {

  @Test("only the open file and the most recent change are candidates")
  func openFilePlusLatestChangeOnly() {
    let fileNames = SimulatorPreviewSpotlightView.candidateFileNames(
      openFileName: "HomeScreen.swift",
      changedFiles: ["AnswerButton.swift", "PrimaryButton.swift", "GamePlayScreen.swift"]
    )
    #expect(fileNames == ["HomeScreen.swift", "AnswerButton.swift"])
  }

  @Test("without an open file, only the most recent change shows")
  func latestChangeOnly() {
    let fileNames = SimulatorPreviewSpotlightView.candidateFileNames(
      openFileName: nil,
      changedFiles: ["AnswerButton.swift", "PrimaryButton.swift", "HomeScreen.swift"]
    )
    #expect(fileNames == ["AnswerButton.swift"])
  }

  @Test("open file matching the latest change is not duplicated")
  func openFileDeduplicated() {
    let fileNames = SimulatorPreviewSpotlightView.candidateFileNames(
      openFileName: "AnswerButton.swift",
      changedFiles: ["AnswerButton.swift", "PrimaryButton.swift"]
    )
    #expect(fileNames == ["AnswerButton.swift"])
  }

  @Test("non-Swift open files are ignored")
  func nonSwiftOpenFileIgnored() {
    let fileNames = SimulatorPreviewSpotlightView.candidateFileNames(
      openFileName: "README.md",
      changedFiles: ["AnswerButton.swift"]
    )
    #expect(fileNames == ["AnswerButton.swift"])
  }

  @Test("no signals means no candidates")
  func empty() {
    #expect(SimulatorPreviewSpotlightView.candidateFileNames(
      openFileName: nil, changedFiles: []).isEmpty)
  }
}
