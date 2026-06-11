import Testing

@testable import SimulatorPreview

@Suite("HotReloadLaunchConfiguration")
struct HotReloadLaunchConfigurationTests {

  private let artifacts = HotReloadArtifacts(
    injectionDylibPath: "/store/PackageFrameworks/AgentHubInjection.framework/AgentHubInjection",
    previewHostDylibPath: "/store/PackageFrameworks/AgentHubPreviewHost.framework/AgentHubPreviewHost",
    frameworkSearchPaths: ["/store/PackageFrameworks", "/store/artifacts/sim"]
  )

  @Test("both features inserted, env complete")
  func fullEnvironment() {
    let configuration = HotReloadLaunchConfiguration(
      projectPath: "/Users/dev/App",
      artifacts: artifacts,
      enableInjection: true,
      enablePreviews: true
    )
    let env = configuration.simctlChildEnvironment(homeDirectory: "/Users/dev")

    #expect(env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] ==
      "/store/PackageFrameworks/AgentHubInjection.framework/AgentHubInjection:"
      + "/store/PackageFrameworks/AgentHubPreviewHost.framework/AgentHubPreviewHost")
    #expect(env["SIMCTL_CHILD_DYLD_FRAMEWORK_PATH"] ==
      "/store/PackageFrameworks:/store/artifacts/sim")
    #expect(env["SIMCTL_CHILD_AGENTHUB_PREVIEW_HOST"] == "1")
    #expect(env["SIMCTL_CHILD_INJECTION_DIRECTORIES"] ==
      "/Users/dev/App,/Users/dev/Library")
    #expect(configuration.isEffective)
  }

  @Test("previews only — no injection env, no build overrides")
  func previewsOnly() {
    let configuration = HotReloadLaunchConfiguration(
      projectPath: "/Users/dev/App",
      artifacts: artifacts,
      enableInjection: false,
      enablePreviews: true
    )
    let env = configuration.simctlChildEnvironment(homeDirectory: "/Users/dev")

    #expect(env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] ==
      "/store/PackageFrameworks/AgentHubPreviewHost.framework/AgentHubPreviewHost")
    #expect(env["SIMCTL_CHILD_INJECTION_DIRECTORIES"] == nil)
    #expect(env["SIMCTL_CHILD_AGENTHUB_PREVIEW_HOST"] == "1")
    #expect(configuration.xcodebuildSettingOverrides.isEmpty)
  }

  @Test("injection enabled adds interposable + frontend-command settings")
  func injectionBuildSettings() {
    let configuration = HotReloadLaunchConfiguration(
      projectPath: "/Users/dev/App",
      artifacts: artifacts,
      enableInjection: true,
      enablePreviews: false
    )
    #expect(configuration.xcodebuildSettingOverrides == [
      "OTHER_LDFLAGS=$(inherited) -Xlinker -interposable",
      "EMIT_FRONTEND_COMMAND_LINES=YES",
    ])
    let env = configuration.simctlChildEnvironment(homeDirectory: "/Users/dev")
    #expect(env["SIMCTL_CHILD_AGENTHUB_PREVIEW_HOST"] == nil)
  }

  @Test("missing artifacts produce an empty environment")
  func missingArtifacts() {
    let configuration = HotReloadLaunchConfiguration(
      projectPath: "/Users/dev/App",
      artifacts: HotReloadArtifacts(
        injectionDylibPath: nil,
        previewHostDylibPath: nil,
        frameworkSearchPaths: []
      ),
      enableInjection: true,
      enablePreviews: true
    )
    #expect(configuration.simctlChildEnvironment(homeDirectory: "/Users/dev").isEmpty)
    #expect(!configuration.isEffective)
  }

  @Test("feature disabled even though artifact exists")
  func disabledFeatures() {
    let configuration = HotReloadLaunchConfiguration(
      projectPath: "/Users/dev/App",
      artifacts: artifacts,
      enableInjection: false,
      enablePreviews: false
    )
    #expect(configuration.simctlChildEnvironment(homeDirectory: "/Users/dev").isEmpty)
    #expect(!configuration.isEffective)
  }
}
