import Foundation
import Testing

@testable import AgentHubCore

@Suite("Terminal workspace linked session snapshots")
struct TerminalWorkspaceLinkedSessionSnapshotTests {
  @Test("Version one tab snapshots decode without linked session metadata")
  func versionOneDecodeKeepsLinkedSessionNil() throws {
    let json = """
    {
      "schemaVersion": 1,
      "activePanelIndex": 0,
      "panels": [
        {
          "role": "primary",
          "activeTabIndex": 0,
          "tabs": [
            {
              "role": "agent",
              "name": "Claude",
              "workingDirectory": "/tmp/project"
            }
          ]
        }
      ]
    }
    """

    let snapshot = try JSONDecoder().decode(
      TerminalWorkspaceSnapshot.self,
      from: Data(json.utf8)
    )

    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.panels.first?.tabs.first?.linkedSession == nil)
  }

  @Test("Linked child session metadata round-trips")
  func linkedSessionRoundTrip() throws {
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .agent,
              name: "Codex",
              workingDirectory: "/tmp/project",
              linkedSession: TerminalWorkspaceLinkedSessionSnapshot(
                provider: .codex,
                sessionId: "child-1"
              )
            )
          ]
        )
      ]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalWorkspaceSnapshot.self, from: data)

    #expect(decoded == snapshot)
    #expect(decoded.schemaVersion == 2)
  }
}
