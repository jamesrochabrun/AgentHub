import Testing

@testable import AgentHubCore

@Suite("Terminal workspace snapshots")
struct TerminalWorkspaceSnapshotTests {

  @Test("Version 1 snapshots decode without layout")
  func versionOneSnapshotDecodesWithoutLayout() throws {
    let data = """
    {
      "schemaVersion": 1,
      "activePanelIndex": 0,
      "panels": [
        {
          "role": "primary",
          "activeTabIndex": 0,
          "tabs": [
            { "role": "agent", "name": "Agent", "title": "Claude", "workingDirectory": "/tmp/project" }
          ]
        }
      ]
    }
    """.data(using: .utf8)!

    let snapshot = try JSONDecoder().decode(TerminalWorkspaceSnapshot.self, from: data)

    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.layout == nil)
    #expect(snapshot.panels.count == 1)
  }

  @Test("Version 2 layout snapshots round-trip")
  func versionTwoLayoutRoundTrips() throws {
    let snapshot = TerminalWorkspaceSnapshot(
      schemaVersion: 2,
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .agent)]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell)]
        ),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell)]
        )
      ],
      activePanelIndex: 2,
      layout: .split(
        axis: .vertical,
        children: [
          .panel(index: 0),
          .split(axis: .horizontal, children: [.panel(index: 1), .panel(index: 2)])
        ]
      )
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalWorkspaceSnapshot.self, from: data)

    #expect(decoded == snapshot)
  }
}
