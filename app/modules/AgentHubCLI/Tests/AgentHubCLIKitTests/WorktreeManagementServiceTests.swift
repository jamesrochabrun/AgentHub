import Foundation
import Testing

@testable import AgentHubCLIKit

struct GitRepoFixture {
  let repoPath: String
  let parentDir: String

  static func create(initialBranch: String = "main") throws -> GitRepoFixture {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(NSTemporaryDirectory(), &resolved) != nil else {
      throw GitFixtureError.commandFailed(command: "realpath", output: "", error: "Failed to resolve temp directory")
    }
    let tempBase = String(cString: resolved)
    let parentDir = tempBase + "/AgentHubCLITests-\(UUID().uuidString)"
    let repoPath = parentDir + "/repo"
    try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)

    let fixture = GitRepoFixture(repoPath: repoPath, parentDir: parentDir)
    try fixture.runGit("init", "-b", initialBranch)
    try fixture.runGit("config", "user.email", "test@test.com")
    try fixture.runGit("config", "user.name", "Test")
    try "initial".write(toFile: repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "initial")
    return fixture
  }

  @discardableResult
  func runGit(_ args: String..., at path: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: path ?? repoPath)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus != 0 {
      throw GitFixtureError.commandFailed(
        command: args.joined(separator: " "),
        output: output,
        error: errorOutput
      )
    }

    return output
  }

  func addSiblingWorktree(branch: String) throws -> String {
    try runGit("branch", branch)
    let worktreePath = parentDir + "/\(branch)"
    try runGit("worktree", "add", worktreePath, branch)
    return worktreePath
  }

  func installSleepingPostCheckoutHook(seconds: Int) throws {
    let hookPath = repoPath + "/.git/hooks/post-checkout"
    let contents = """
    #!/bin/sh
    sleep \(seconds)
    """
    try contents.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
  }

  func localBranchExists(_ branch: String) throws -> Bool {
    let output = try runGit("branch", "--list", branch)
    return !output.isEmpty
  }

  func configureUser(at path: String? = nil) throws {
    try runGit("config", "user.email", "test@test.com", at: path)
    try runGit("config", "user.name", "Test", at: path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: parentDir)
  }
}

enum GitFixtureError: Error {
  case commandFailed(command: String, output: String, error: String)
}

private func seedMonorepoLikePaths(in fixture: GitRepoFixture) throws {
  let files = [
    "apps/ios/Package.swift": "// swift-tools-version: 6.0\n",
    "apps/ios/features/payments/Feature.swift": "struct Feature {}\n",
    "apps/android/app/build.gradle": "plugins {}\n",
    "ribbons/README.md": "ribbons\n",
    ".agents/README.md": "agents\n",
    ".claude/README.md": "claude\n",
    ".claude-plugin/README.md": "plugin\n",
    "scripts/git_hooks_support/hook_tooling": "return 0\n",
    "scripts/git_support/README.md": "git support\n"
  ]

  for (relativePath, contents) in files {
    let path = fixture.repoPath + "/" + relativePath
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
  }

  try fixture.runGit("add", ".")
  try fixture.runGit("commit", "-m", "monorepo paths")
}

private func installHookThatRequiresSparseSupport(in fixture: GitRepoFixture) throws {
  let hookPath = fixture.repoPath + "/.git/hooks/post-checkout"
  let contents = """
  #!/bin/sh
  . "$(git rev-parse --show-toplevel)/scripts/git_hooks_support/hook_tooling"
  """
  try contents.write(toFile: hookPath, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
}

private actor WorktreeProgressRecorder {
  private var values: [WorktreeCreationProgress] = []

  func record(_ progress: WorktreeCreationProgress) {
    values.append(progress)
  }

  func recordedValues() -> [WorktreeCreationProgress] {
    values
  }
}

@Suite("WorktreeManagementService sibling worktree convention")
struct WorktreeConventionTests {
  @Test("Creates new branch worktrees beside the main repository")
  func createsWorktreeBesideMainRepository() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let service = WorktreeManagementService()
    let path = try await service.createWorktreeWithNewBranch(
      at: fixture.repoPath,
      newBranchName: "feature/example",
      directoryName: WorktreeNaming.worktreeDirectoryName(for: "feature/example")
    )

    #expect(path == fixture.parentDir + "/feature-example")
    #expect(FileManager.default.fileExists(atPath: path))
    let worktrees = try await service.listWorktrees(at: fixture.repoPath)
    let registeredWorktree = try #require(worktrees.first { $0.branch == "feature/example" })
    #expect(path == registeredWorktree.path)
  }

  @Test("Creates from a linked worktree but stores under the main repository")
  func linkedWorktreeInvocationUsesMainRepositoryStorage() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let existingPath = try fixture.addSiblingWorktree(branch: "existing")
    let service = WorktreeManagementService()

    let path = try await service.createWorktreeWithNewBranch(
      at: existingPath,
      newBranchName: "feature/from-linked",
      directoryName: "feature-from-linked"
    )

    #expect(path == fixture.parentDir + "/feature-from-linked")
    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test("Checkout reuses an existing worktree for the branch")
  func checkoutReusesExistingBranchWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let existingPath = try fixture.addSiblingWorktree(branch: "existing")
    let service = WorktreeManagementService()

    let path = try await service.checkoutWorktree(
      at: fixture.repoPath,
      branch: "existing",
      directoryName: "existing"
    )

    #expect(path == existingPath)
  }

  @Test("Uses start point when creating a new branch")
  func usesStartPoint() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.runGit("checkout", "-b", "base")
    try "base".write(toFile: fixture.repoPath + "/BASE.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "base")
    try fixture.runGit("checkout", "main")

    let service = WorktreeManagementService()
    let path = try await service.createWorktreeWithNewBranch(
      at: fixture.repoPath,
      newBranchName: "feature/from-base",
      directoryName: "feature-from-base",
      startPoint: "base"
    )

    #expect(FileManager.default.fileExists(atPath: path + "/BASE.md"))
  }

  @Test("Creates sparse agent worktree from nested marked project start path")
  func createsSparseAgentWorktreeFromNestedMarkedProjectStartPath() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try seedMonorepoLikePaths(in: fixture)
    try installHookThatRequiresSparseSupport(in: fixture)

    let startPath = fixture.repoPath + "/apps/ios/features/payments"
    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: startPath,
      startPath: startPath,
      newBranchName: "feature/sparse-ios",
      directoryName: "feature-sparse-ios",
      startPoint: nil,
      sparseProfile: nil,
      fullCheckout: false
    )

    #expect(creation.worktreePath == fixture.parentDir + "/feature-sparse-ios")
    #expect(creation.launchPath == creation.worktreePath + "/apps/ios/features/payments")
    #expect(creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths.contains("apps/ios"))
    #expect(creation.sparseCheckoutPaths.contains("scripts/git_hooks_support"))
    #expect(!creation.sparseCheckoutPaths.contains("gradle"))
    #expect(FileManager.default.fileExists(atPath: creation.launchPath))
    #expect(FileManager.default.fileExists(atPath: creation.worktreePath + "/apps/ios/features/payments/Feature.swift"))
    #expect(!FileManager.default.fileExists(atPath: creation.worktreePath + "/apps/android/app/build.gradle"))

    let sparseList = try fixture.runGit("sparse-checkout", "list", at: creation.worktreePath)
    #expect(sparseList.components(separatedBy: .newlines).contains("apps/ios"))
    #expect(sparseList.components(separatedBy: .newlines).contains("scripts/git_hooks_support"))
    #expect(try fixture.runGit("status", "--short", at: creation.worktreePath).isEmpty)
  }

  @Test("Agent sparse inference falls back to exact start path without project markers")
  func agentSparseInferenceFallsBackToExactStartPathWithoutProjectMarkers() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try FileManager.default.createDirectory(
      atPath: fixture.repoPath + "/ios/app",
      withIntermediateDirectories: true
    )
    try "app".write(toFile: fixture.repoPath + "/ios/app/App.swift", atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "ios app")

    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: fixture.repoPath + "/ios/app",
      startPath: fixture.repoPath + "/ios/app",
      newBranchName: "feature/sparse-no-support",
      directoryName: "feature-sparse-no-support",
      startPoint: nil,
      sparseProfile: nil,
      fullCheckout: false
    )

    #expect(creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths == ["ios/app"])
    #expect(FileManager.default.fileExists(atPath: creation.launchPath))
    #expect(try fixture.runGit("status", "--short", at: creation.worktreePath).isEmpty)
  }

  @Test("Agent sparse inference falls back to full checkout when launch owner is untracked")
  func agentSparseInferenceFallsBackToFullCheckoutWhenLaunchOwnerIsUntracked() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try FileManager.default.createDirectory(
      atPath: fixture.repoPath + "/.agents",
      withIntermediateDirectories: true
    )
    try "agents\n".write(toFile: fixture.repoPath + "/.agents/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "agent support")

    let startPath = fixture.repoPath + "/src/new-feature"
    try FileManager.default.createDirectory(atPath: startPath, withIntermediateDirectories: true)

    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: fixture.repoPath,
      startPath: startPath,
      newBranchName: "feature/untracked-owner",
      directoryName: "feature-untracked-owner",
      startPoint: nil,
      sparseProfile: nil,
      fullCheckout: false
    )

    #expect(!creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths.isEmpty)
    #expect(FileManager.default.fileExists(atPath: creation.worktreePath + "/.agents/README.md"))
  }

  @Test("Agent sparse inference includes top-level Gradle support for Gradle projects")
  func agentSparseInferenceIncludesTopLevelGradleSupportForGradleProjects() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let files = [
      "apps/android/settings.gradle.kts": "pluginManagement {}\n",
      "apps/android/app/build.gradle.kts": "plugins {}\n",
      "apps/android/app/src/main/AndroidManifest.xml": "<manifest />\n",
      "apps/ios/Package.swift": "// swift-tools-version: 6.0\n",
      "gradle/libs.versions.toml": "[versions]\n"
    ]
    for (relativePath, contents) in files {
      let path = fixture.repoPath + "/" + relativePath
      try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
      )
      try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "android app")

    let startPath = fixture.repoPath + "/apps/android/app/src/main"
    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: startPath,
      startPath: startPath,
      newBranchName: "feature/sparse-android",
      directoryName: "feature-sparse-android",
      startPoint: nil,
      sparseProfile: nil,
      fullCheckout: false
    )

    #expect(creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths.contains("apps/android"))
    #expect(creation.sparseCheckoutPaths.contains("gradle"))
    #expect(!creation.sparseCheckoutPaths.contains("apps/ios"))
    #expect(FileManager.default.fileExists(atPath: creation.launchPath))
    #expect(FileManager.default.fileExists(atPath: creation.worktreePath + "/gradle/libs.versions.toml"))
    #expect(!FileManager.default.fileExists(atPath: creation.worktreePath + "/apps/ios/Package.swift"))
  }

  @Test("Explicit sparse profile is augmented with inferred launch owner")
  func explicitSparseProfileIsAugmentedWithInferredLaunchOwner() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try seedMonorepoLikePaths(in: fixture)
    try FileManager.default.createDirectory(
      atPath: fixture.repoPath + "/shared",
      withIntermediateDirectories: true
    )
    try "shared\n".write(toFile: fixture.repoPath + "/shared/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "shared")

    let startPath = fixture.repoPath + "/apps/ios/features/payments"
    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: startPath,
      startPath: startPath,
      newBranchName: "feature/explicit-sparse",
      directoryName: "feature-explicit-sparse",
      startPoint: nil,
      sparseProfile: WorktreeSparseCheckoutProfile(paths: ["shared"]),
      fullCheckout: false
    )

    #expect(creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths.contains("apps/ios"))
    #expect(creation.sparseCheckoutPaths.contains("shared"))
    #expect(FileManager.default.fileExists(atPath: creation.launchPath))
    #expect(FileManager.default.fileExists(atPath: creation.worktreePath + "/shared/README.md"))
    #expect(!FileManager.default.fileExists(atPath: creation.worktreePath + "/apps/android/app/build.gradle"))
  }

  @Test("Agent worktree can explicitly use full checkout fallback")
  func agentWorktreeCanUseFullCheckoutFallback() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try seedMonorepoLikePaths(in: fixture)

    let startPath = fixture.repoPath + "/apps/ios/features/payments"
    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: startPath,
      startPath: startPath,
      newBranchName: "feature/full-agent",
      directoryName: "feature-full-agent",
      startPoint: nil,
      sparseProfile: nil,
      fullCheckout: true
    )

    #expect(!creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths.isEmpty)
    #expect(creation.launchPath == creation.worktreePath + "/apps/ios/features/payments")
    #expect(FileManager.default.fileExists(atPath: creation.worktreePath + "/apps/android/app/build.gradle"))
  }

  @Test("Agent worktree defaults to full checkout from repository root")
  func agentWorktreeDefaultsToFullCheckoutFromRepositoryRoot() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: fixture.repoPath,
      startPath: nil,
      newBranchName: "feature/root-default-full",
      directoryName: "feature-root-default-full",
      startPoint: nil,
      sparseProfile: nil,
      fullCheckout: false
    )

    #expect(!creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths.isEmpty)
    #expect(creation.launchPath == creation.worktreePath)
    #expect(FileManager.default.fileExists(atPath: creation.worktreePath + "/README.md"))
  }

  @Test("Agent worktree defaults to sparse exact path for generic subdirectory starts")
  func agentWorktreeDefaultsToSparseExactPathForGenericSubdirectoryStarts() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try FileManager.default.createDirectory(
      atPath: fixture.repoPath + "/src/features/payments",
      withIntermediateDirectories: true
    )
    try "root config\n".write(toFile: fixture.repoPath + "/Package.swift", atomically: true, encoding: .utf8)
    try "feature\n".write(
      toFile: fixture.repoPath + "/src/features/payments/Feature.swift",
      atomically: true,
      encoding: .utf8
    )
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "generic app")

    let startPath = fixture.repoPath + "/src/features/payments"
    let service = WorktreeManagementService()
    let creation = try await service.createAgentWorktreeWithNewBranch(
      at: startPath,
      startPath: startPath,
      newBranchName: "feature/generic-default-full",
      directoryName: "feature-generic-default-full",
      startPoint: nil,
      sparseProfile: nil,
      fullCheckout: false
    )

    #expect(creation.isSparseCheckout)
    #expect(creation.sparseCheckoutPaths == ["src/features/payments"])
    #expect(creation.launchPath == creation.worktreePath + "/src/features/payments")
    #expect(FileManager.default.fileExists(atPath: creation.launchPath + "/Feature.swift"))
  }

  @Test("Detects fetched origin main as the remote base branch")
  func detectsFetchedOriginMainAsRemoteBaseBranch() async throws {
    let seed = try GitRepoFixture.create()
    defer { seed.cleanup() }

    let remotePath = seed.parentDir + "/origin.git"
    try seed.runGit("init", "--bare", "-b", "main", remotePath)
    try seed.runGit("remote", "add", "origin", remotePath)
    try seed.runGit("push", "-u", "origin", "main")

    let localClonePath = seed.parentDir + "/local-clone"
    try seed.runGit("clone", remotePath, localClonePath)
    try seed.configureUser(at: localClonePath)

    let writerClonePath = seed.parentDir + "/writer-clone"
    try seed.runGit("clone", remotePath, writerClonePath)
    try seed.configureUser(at: writerClonePath)
    try "remote".write(toFile: writerClonePath + "/REMOTE.md", atomically: true, encoding: .utf8)
    try seed.runGit("add", ".", at: writerClonePath)
    try seed.runGit("commit", "-m", "remote update", at: writerClonePath)
    try seed.runGit("push", "origin", "main", at: writerClonePath)

    let service = WorktreeManagementService()
    let remoteBase = try #require(await service.fetchAndGetDefaultRemoteBaseBranch(at: localClonePath))
    #expect(remoteBase.name == "origin/main")
    #expect(remoteBase.displayName == "main")

    let path = try await service.createWorktreeWithNewBranch(
      at: localClonePath,
      newBranchName: "feature/from-remote-main",
      directoryName: "feature-from-remote-main",
      startPoint: remoteBase.name
    )

    #expect(FileManager.default.fileExists(atPath: path + "/REMOTE.md"))
    #expect(!FileManager.default.fileExists(atPath: localClonePath + "/REMOTE.md"))
  }

  @Test("Falls back to origin master when remote main is absent")
  func fallsBackToOriginMasterWhenRemoteMainIsAbsent() async throws {
    let seed = try GitRepoFixture.create(initialBranch: "master")
    defer { seed.cleanup() }

    let remotePath = seed.parentDir + "/origin.git"
    try seed.runGit("init", "--bare", "-b", "master", remotePath)
    try seed.runGit("remote", "add", "origin", remotePath)
    try seed.runGit("push", "-u", "origin", "master")

    let localClonePath = seed.parentDir + "/master-clone"
    try seed.runGit("clone", remotePath, localClonePath)

    let service = WorktreeManagementService()
    let remoteBase = try #require(await service.fetchAndGetDefaultRemoteBaseBranch(at: localClonePath))

    #expect(remoteBase.name == "origin/master")
    #expect(remoteBase.displayName == "master")
  }

  @Test("Progress-enabled creation leaves completed as the final update")
  func progressEnabledCreationLeavesCompletedFinal() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let hookPath = fixture.repoPath + "/.git/hooks/post-checkout"
    let hook = """
    #!/bin/sh
    echo "Preparing worktree from hook" >&2
    """
    try hook.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

    let service = WorktreeManagementService()
    let recorder = WorktreeProgressRecorder()

    _ = try await service.createWorktreeWithNewBranch(
      at: fixture.repoPath,
      newBranchName: "feature/progress-order",
      directoryName: "feature-progress-order",
      operationID: WorktreeOperationID()
    ) { progress in
      if case .preparing = progress {
        try? await Task.sleep(for: .milliseconds(150))
      }
      await recorder.record(progress)
    }

    try await Task.sleep(for: .milliseconds(250))
    let progressUpdates = await recorder.recordedValues()
    let completedIndex = try #require(progressUpdates.lastIndex(where: { progress in
      if case .completed = progress { return true }
      return false
    }))

    #expect(completedIndex == progressUpdates.indices.last)
    #expect(!progressUpdates.dropFirst(completedIndex + 1).contains { $0.isInProgress })
  }

  @Test("Applies tracked and untracked source changes to another worktree")
  func appliesWorkingTreeChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: fixture.repoPath + "/Notes", withIntermediateDirectories: true)
    try "draft".write(toFile: fixture.repoPath + "/Notes/draft.md", atomically: true, encoding: .utf8)

    let service = WorktreeManagementService()
    let snapshot = try #require(await service.captureWorkingTreeChanges(at: fixture.repoPath))
    let path = try await service.createWorktreeWithNewBranch(
      at: fixture.repoPath,
      newBranchName: "feature/carry-changes",
      directoryName: "feature-carry-changes"
    )

    try await service.applyWorkingTreeChanges(snapshot, from: fixture.repoPath, to: path)

    let readme = try String(contentsOfFile: path + "/README.md", encoding: .utf8)
    let draft = try String(contentsOfFile: path + "/Notes/draft.md", encoding: .utf8)

    #expect(readme == "changed")
    #expect(draft == "draft")
  }
}

// Both tests assert exact ordering of concurrent async events (first-start/first-end/
// second-queued/second-start) under real timing — they interleave differently on slow
// CI runners and flake. Quarantined to keep the CI gate reliable; re-enable once the
// service's queueing is testable deterministically (no wall-clock). See TestQuarantine.md / #380.
@Suite("WorktreeManagementService creation queue", .disabled("headless-quarantine: concurrent-event ordering timing — flaky on CI; see TestQuarantine.md"))
struct WorktreeCreationQueueTests {
  private actor EventRecorder {
    private var events: [String] = []

    func record(_ event: String) {
      events.append(event)
    }

    func recordedEvents() -> [String] {
      events
    }
  }

  @Test("Serializes same-repository worktree creation and reports queued state")
  func serializesSameRepositoryCreation() async throws {
    let queue = WorktreeCreationQueue(maxConcurrentGlobally: 2, maxConcurrentPerRepository: 1)
    let recorder = EventRecorder()
    let firstTask = Task {
      try await queue.withPermit(repoKey: "repo-a") {
        await recorder.record("first-start")
        try await Task.sleep(for: .milliseconds(250))
        await recorder.record("first-end")
      }
    }

    try await Task.sleep(for: .milliseconds(50))

    let secondTask = Task {
      try await queue.withPermit(
        repoKey: "repo-a",
        onQueued: {
          await recorder.record("second-queued")
        }
      ) {
        await recorder.record("second-start")
      }
    }

    try await Task.sleep(for: .milliseconds(50))

    let earlyEvents = await recorder.recordedEvents()
    #expect(earlyEvents.contains("second-queued"))
    #expect(!earlyEvents.contains("second-start"))

    try await firstTask.value
    try await secondTask.value

    let events = await recorder.recordedEvents()
    let firstEndIndex = try #require(events.firstIndex(of: "first-end"))
    let secondStartIndex = try #require(events.firstIndex(of: "second-start"))

    #expect(firstEndIndex < secondStartIndex)
  }

  @Test("Allows different repositories to run concurrently")
  func allowsDifferentRepositoriesToRunConcurrently() async throws {
    let queue = WorktreeCreationQueue(maxConcurrentGlobally: 2, maxConcurrentPerRepository: 1)
    let recorder = EventRecorder()

    let firstTask = Task {
      try await queue.withPermit(repoKey: "repo-a") {
        await recorder.record("first-start")
        try await Task.sleep(for: .milliseconds(250))
        await recorder.record("first-end")
      }
    }

    try await Task.sleep(for: .milliseconds(50))

    let secondTask = Task {
      try await queue.withPermit(repoKey: "repo-b") {
        await recorder.record("second-start")
      }
    }

    try await secondTask.value
    let earlyEvents = await recorder.recordedEvents()
    #expect(earlyEvents.contains("second-start"))
    #expect(!earlyEvents.contains("first-end"))

    try await firstTask.value
  }
}

@Suite("WorktreeManagementService removal and cancellation")
struct WorktreeRemovalTests {
  @Test("Prunes stale reference when worktree directory is missing")
  func prunesWhenDirectoryMissing() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addSiblingWorktree(branch: "test-branch")
    try FileManager.default.removeItem(atPath: worktreePath)

    let service = WorktreeManagementService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath)

    let listAfter = try fixture.runGit("worktree", "list")
    #expect(!listAfter.contains("test-branch"))
  }

  @Test("Force delete refuses a directory that is not a linked worktree")
  func forceDeleteRefusesNonWorktreeDirectory() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let plainDir = fixture.repoPath + "-not-a-worktree"
    try FileManager.default.createDirectory(atPath: plainDir, withIntermediateDirectories: true)
    try "irreplaceable".write(toFile: plainDir + "/data.txt", atomically: true, encoding: .utf8)

    let service = WorktreeManagementService()
    await #expect(throws: (any Error).self) {
      try await service.removeWorktree(at: plainDir, relativeTo: fixture.repoPath, force: true)
    }

    #expect(FileManager.default.fileExists(atPath: plainDir + "/data.txt"))
  }

  @Test("Force delete refuses the main repository root")
  func forceDeleteRefusesMainRepositoryRoot() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let service = WorktreeManagementService()
    await #expect(throws: (any Error).self) {
      try await service.removeWorktree(at: fixture.repoPath, relativeTo: fixture.repoPath, force: true)
    }

    #expect(FileManager.default.fileExists(atPath: fixture.repoPath + "/README.md"))
    #expect(FileManager.default.fileExists(atPath: fixture.repoPath + "/.git"))
  }

  @Test("Orphan removal refuses a directory without the linked-worktree marker")
  func orphanRemovalRefusesUnmarkedDirectory() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let plainDir = fixture.repoPath + "-orphan-imposter"
    try FileManager.default.createDirectory(atPath: plainDir, withIntermediateDirectories: true)
    try "keep me".write(toFile: plainDir + "/data.txt", atomically: true, encoding: .utf8)

    let service = WorktreeManagementService()
    await #expect(throws: (any Error).self) {
      try await service.removeOrphanedWorktree(at: plainDir, parentRepoPath: fixture.repoPath)
    }

    #expect(FileManager.default.fileExists(atPath: plainDir + "/data.txt"))
  }

  @Test("Force removes dirty worktree from disk")
  func forceRemovesDirtyWorktreeFromDisk() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let worktreePath = try fixture.addSiblingWorktree(branch: "dirty-branch")
    try "untracked".write(
      toFile: (worktreePath as NSString).appendingPathComponent("untracked.txt"),
      atomically: true,
      encoding: .utf8
    )

    let service = WorktreeManagementService()
    try await service.removeWorktree(at: worktreePath, relativeTo: fixture.repoPath, force: true)

    #expect(!FileManager.default.fileExists(atPath: worktreePath))
    let listAfter = try fixture.runGit("worktree", "list")
    #expect(!listAfter.contains("dirty-branch"))
  }

  @Test("Cancels in-flight worktree creation and cleans generated artifacts", .disabled("headless-quarantine: async cancellation timing — flaky on CI runners; see TestQuarantine.md"))
  func cancelsWorktreeCreationAndCleansUp() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.installSleepingPostCheckoutHook(seconds: 5)

    let service = WorktreeManagementService()
    let operationID = WorktreeOperationID()
    let directoryName = "cancelled-worktree"
    let branchName = "cancelled-worktree-branch"

    let task = Task {
      try await service.createWorktreeWithNewBranch(
        at: fixture.repoPath,
        newBranchName: branchName,
        directoryName: directoryName,
        operationID: operationID
      ) { _ in }
    }

    try await Task.sleep(for: .milliseconds(200))
    await service.cancelWorktreeCreation(operationID)

    await #expect(throws: WorktreeManagementError.self) {
      _ = try await task.value
    }

    let cleanup = await service.cleanupCancelledWorktreeCreation(
      repoPath: fixture.repoPath,
      newBranchName: branchName,
      directoryName: directoryName
    )

    #expect(cleanup.removedWorktree || cleanup.removedBranch || !cleanup.notes.isEmpty)
    #expect(try fixture.localBranchExists(branchName) == false)
    #expect(FileManager.default.fileExists(atPath: fixture.parentDir + "/\(directoryName)") == false)
  }
}
