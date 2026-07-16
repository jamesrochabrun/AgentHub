import Foundation
import Testing

@testable import AgentHubCore

@Suite("Terminal workspace snapshot v4")
struct TerminalWorkspaceSnapshotV4Tests {
  @Test("v3 snapshots decode with equal-ratio fallback data absent")
  func v3BackwardCompatibility() throws {
    let json = """
    {
      "schemaVersion": 3,
      "panels": [
        {
          "role": "primary",
          "tabs": [{ "role": "shell", "workingDirectory": "/tmp/project" }],
          "activeTabIndex": 0
        }
      ],
      "activePanelIndex": 0,
      "splitLayout": null
    }
    """

    let snapshot = try JSONDecoder().decode(
      TerminalWorkspaceSnapshot.self,
      from: Data(json.utf8)
    )

    #expect(snapshot.schemaVersion == 3)
    #expect(snapshot.splitRatiosByPath.isEmpty)
    #expect(snapshot.panels.count == 1)
  }

  @Test("v4 ratios round-trip for more than four panes")
  func ratiosRoundTrip() throws {
    let snapshot = TerminalWorkspaceSnapshot(
      panels: (0..<6).map { index in
        TerminalWorkspacePanelSnapshot(
          role: index == 0 ? .primary : .auxiliary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp/\(index)")]
        )
      },
      splitLayout: .split(
        axis: .horizontal,
        children: (0..<6).map { .panel(index: $0) }
      ),
      splitRatiosByPath: ["root": [1, 2, 3, 4, 5, 6]]
    )

    let decoded = try JSONDecoder().decode(
      TerminalWorkspaceSnapshot.self,
      from: JSONEncoder().encode(snapshot)
    )

    #expect(decoded == snapshot)
    #expect(decoded.schemaVersion == 4)
    #expect(decoded.panels.count == 6)
  }

  @Test("Malformed and obsolete ratios normalize safely")
  func malformedRatiosNormalize() {
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [],
      splitLayout: .split(
        axis: .horizontal,
        children: [
          .panel(index: 0),
          .split(
            axis: .vertical,
            children: [.panel(index: 1), .panel(index: 2)]
          )
        ]
      ),
      splitRatiosByPath: [
        "root": [0],
        "root.1": [2, 6],
        "obsolete": [0.2, 0.8]
      ]
    )

    let normalized = snapshot.normalizedSplitRatios()

    #expect(normalized["root"] == [0.5, 0.5])
    #expect(normalized["root.1"] == [0.25, 0.75])
    #expect(normalized["obsolete"] == nil)
  }
}
