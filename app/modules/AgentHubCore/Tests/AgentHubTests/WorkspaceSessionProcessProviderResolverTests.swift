import Darwin
import Testing

@testable import AgentHubCore

@Suite("Workspace session process provider resolver")
struct WorkspaceSessionProcessProviderResolverTests {
  @Test("Identifies Claude and Codex foreground commands")
  func identifiesProviders() async {
    let inspector = WorkspaceProcessInspectorStub(
      identities: [
        101: workspaceIdentity(
          pid: 101,
          command: "/Users/test/.claude/local/node_modules/.bin/claude --model sonnet"
        ),
        202: workspaceIdentity(
          pid: 202,
          command: "/opt/codex/vendor/aarch64-apple-darwin/bin/codex"
        ),
        303: workspaceIdentity(pid: 303, command: "/bin/zsh")
      ]
    )
    let resolver = WorkspaceSessionProcessProviderResolver(processInspector: inspector)
    let executables: [SessionProviderKind: String] = [
      .claude: "claude",
      .codex: "codex"
    ]

    #expect(await resolver.provider(for: 101, executableNames: executables) == .claude)
    #expect(await resolver.provider(for: 202, executableNames: executables) == .codex)
    #expect(await resolver.provider(for: 303, executableNames: executables) == nil)
  }

  @Test("Honors custom executable names")
  func customExecutableNames() async {
    let inspector = WorkspaceProcessInspectorStub(
      identities: [
        404: workspaceIdentity(pid: 404, command: "/usr/local/bin/team-agent --interactive")
      ]
    )
    let resolver = WorkspaceSessionProcessProviderResolver(processInspector: inspector)

    #expect(
      await resolver.provider(
        for: 404,
        executableNames: [.claude: "team-agent", .codex: "codex"]
      ) == .claude
    )
  }
}

private actor WorkspaceProcessInspectorStub: ProcessInspecting {
  let identities: [Int32: ManagedProcessIdentity]

  init(identities: [Int32: ManagedProcessIdentity]) {
    self.identities = identities
  }

  func identity(for pid: pid_t) async -> ManagedProcessIdentity? {
    identities[pid]
  }
}

private func workspaceIdentity(pid: Int32, command: String) -> ManagedProcessIdentity {
  ManagedProcessIdentity(
    pid: pid,
    processGroupId: pid,
    startTimeSeconds: 1,
    commandLine: command
  )
}
