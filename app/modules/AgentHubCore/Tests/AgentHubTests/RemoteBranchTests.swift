import Testing

@testable import AgentHubCore

@Suite("RemoteBranch worktree base options")
struct RemoteBranchWorktreeBaseOptionsTests {
  @Test("Remote default branch appears before local branches")
  func remoteDefaultBranchAppearsBeforeLocalBranches() {
    let remoteMain = RemoteBranch(name: "origin/main", remote: "origin")
    let localMain = RemoteBranch(name: "main", remote: "local")
    let localFeature = RemoteBranch(name: "feature/example", remote: "local")

    let options = RemoteBranch.worktreeBaseOptions(
      localBranches: [localFeature, localMain],
      remoteDefaultBranch: remoteMain
    )

    #expect(options == [remoteMain, localFeature, localMain])
    #expect(remoteMain.gitStartPoint == "origin/main")
    #expect(remoteMain.pickerDisplayName == "origin/main (latest remote)")
  }

  @Test("Local branch start point remains the local branch name")
  func localBranchStartPointRemainsLocalBranchName() {
    let localMaster = RemoteBranch(name: "master", remote: "local")

    #expect(localMaster.gitStartPoint == "master")
    #expect(localMaster.pickerDisplayName == "master")
  }
}
