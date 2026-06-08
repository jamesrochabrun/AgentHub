//
//  SessionInvestigationService.swift
//  AgentHub
//
//  Claude-backed local session investigation with deterministic fallback.
//

import AgentHubMCPUI
import Foundation

public protocol SessionInvestigationServiceProtocol: Sendable {
  func investigate(snapshot: SessionInvestigationSnapshot) async throws -> SessionInvestigationReport
  func cancelActiveInvestigation() async
}

public actor ClaudeSessionInvestigationService: SessionInvestigationServiceProtocol {
  private static let logPrefix = "[SESSIONINVESTIGATION]"
  private static let defaultTimeout: Duration = .seconds(30)
  private static let models = ClaudeProgrammaticService.haikuFallbackModels

  private let programmaticService: any ClaudeProgrammaticServiceProtocol
  private let timeout: Duration

  public init(
    programmaticService: any ClaudeProgrammaticServiceProtocol,
    timeout: Duration? = nil
  ) {
    self.programmaticService = programmaticService
    self.timeout = timeout ?? Self.defaultTimeout
  }

  public func investigate(snapshot: SessionInvestigationSnapshot) async throws -> SessionInvestigationReport {
    let snapshotJSON = Self.encodedSnapshot(snapshot)
    let workingDirectory = snapshot.repositories.first?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
    let request = ClaudeProgrammaticRequest(
      systemPrompt: Self.systemPrompt,
      userPrompt: Self.userPrompt(snapshotJSON: snapshotJSON),
      workingDirectory: workingDirectory,
      models: Self.models,
      timeout: timeout,
      permissionMode: nil,
      disallowedTools: Self.readOnlyDisallowedTools,
      logPrefix: Self.logPrefix
    )

    do {
      let raw = try await programmaticService.run(request)
      if let response = SessionInvestigationReportParser.parse(raw) {
        return SessionInvestigationReport(
          generatedAt: snapshot.generatedAt,
          source: .claude,
          overview: snapshot.overview,
          narrative: response.narrative,
          findings: response.findings,
          actions: response.actions,
          rawModelOutput: raw
        )
      }

      AppLogger.intelligence.warning(
        "\(Self.logPrefix, privacy: .public) Claude returned non-JSON investigation output; using deterministic fallback"
      )
      return SessionInvestigationFallbackBuilder.makeReport(
        from: snapshot,
        rawModelOutput: raw
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      AppLogger.intelligence.error(
        "\(Self.logPrefix, privacy: .public) Claude investigation failed: \(ClaudeProgrammaticService.describeError(error), privacy: .public)"
      )
      return SessionInvestigationFallbackBuilder.makeReport(
        from: snapshot,
        rawModelOutput: ClaudeProgrammaticService.failureOutput(from: error)
      )
    }
  }

  public func cancelActiveInvestigation() async {
    await programmaticService.cancelActiveRequest()
  }

  private static let readOnlyDisallowedTools = [
    "Bash",
    "Edit",
    "Write",
    "MultiEdit",
    "NotebookEdit",
    "Task",
    "WebFetch",
    "WebSearch"
  ]

  private static let systemPrompt = """
  You are AgentHub's local session investigator.

  You receive a bounded JSON snapshot of local Claude Code and Codex sessions. The snapshot contains session metadata, monitor state, worktree inventory, and JSONL file paths/attributes. It does not include full transcript contents.

  Analyze only what the snapshot supports. Do not claim a branch is merged, mergeable, or safe to delete unless the evidence is explicit. When the evidence is incomplete, label the recommendation as a candidate and explain what must be verified.

  Return strict JSON only. No markdown fences and no commentary outside JSON.
  """

  private static func userPrompt(snapshotJSON: String) -> String {
    """
    Produce a concise AgentHub session audit.

    Cover:
    - scale: repository, worktree, session, active, monitored, and pending counts
    - sessions needing attention
    - sessions that appear idle or complete
    - worktrees that may be removable
    - branches/sessions that may be merge candidates or already merged, but only if the snapshot supports that conclusion

    Required JSON schema:
    {
      "narrative": "short plain-language report",
      "findings": [
        {
          "title": "short title",
          "detail": "one or two sentences",
          "severity": "info|warning|critical",
          "provider": "Claude|Codex|null",
          "sessionIds": ["session-id"],
          "projectPath": "/path or null",
          "worktreePath": "/path or null"
        }
      ],
      "actions": [
        {
          "title": "short action",
          "detail": "what to do and what to verify",
          "category": "scale|observe|needsAttention|mergeCandidate|merged|deleteWorktreeCandidate|removeFromHub|cleanup|unknown",
          "confidence": "low|medium|high",
          "provider": "Claude|Codex|null",
          "sessionIds": ["session-id"],
          "projectPath": "/path or null",
          "worktreePath": "/path or null"
        }
      ]
    }

    Snapshot JSON:
    \(snapshotJSON)
    """
  }

  private static func encodedSnapshot(_ snapshot: SessionInvestigationSnapshot) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(snapshot),
          let text = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return text
  }
}

struct SessionInvestigationAIResponse: Decodable, Equatable {
  let narrative: String
  let findings: [SessionInvestigationFinding]
  let actions: [SessionInvestigationAction]
}

enum SessionInvestigationReportParser {
  static func parse(_ raw: String) -> SessionInvestigationAIResponse? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    for candidate in jsonCandidates(from: trimmed) {
      guard let data = candidate.data(using: .utf8),
            let response = try? JSONDecoder().decode(SessionInvestigationAIResponse.self, from: data) else {
        continue
      }
      return response
    }

    return nil
  }

  private static func jsonCandidates(from text: String) -> [String] {
    var candidates: [String] = []

    if text.hasPrefix("```") {
      var unfenced = text
      if let newline = unfenced.firstIndex(of: "\n") {
        unfenced = String(unfenced[unfenced.index(after: newline)...])
      } else {
        unfenced = String(unfenced.dropFirst(3))
      }
      if unfenced.hasSuffix("```") {
        unfenced = String(unfenced.dropLast(3))
      }
      let cleaned = unfenced.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleaned.hasPrefix("{") {
        candidates.append(cleaned)
      }
    }

    if text.hasPrefix("{") {
      candidates.append(text)
    }

    if let balanced = firstBalancedJSONObject(in: text) {
      candidates.append(balanced)
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }

  private static func firstBalancedJSONObject(in text: String) -> String? {
    guard let openIndex = text.firstIndex(of: "{") else { return nil }

    var depth = 0
    var inString = false
    var isEscaped = false

    var index = openIndex
    while index < text.endIndex {
      let character = text[index]

      if inString {
        if isEscaped {
          isEscaped = false
        } else if character == "\\" {
          isEscaped = true
        } else if character == "\"" {
          inString = false
        }
      } else {
        if character == "\"" {
          inString = true
        } else if character == "{" {
          depth += 1
        } else if character == "}" {
          depth -= 1
          if depth == 0 {
            return String(text[openIndex...index])
          }
        }
      }

      index = text.index(after: index)
    }

    return nil
  }
}

enum SessionInvestigationFallbackBuilder {
  static func makeReport(
    from snapshot: SessionInvestigationSnapshot,
    rawModelOutput: String? = nil
  ) -> SessionInvestigationReport {
    let overview = snapshot.overview
    var findings: [SessionInvestigationFinding] = [
      SessionInvestigationFinding(
        title: "Session scale",
        detail: "\(overview.sessionCount) sessions across \(overview.repositoryCount) repositories and \(overview.worktreeCount) worktrees. \(overview.monitoredSessionCount) are monitored in AgentHub.",
        severity: .info
      )
    ]

    let attentionSessions = snapshot.sessions.filter(\.isAwaitingApproval)
    if !attentionSessions.isEmpty {
      findings.append(SessionInvestigationFinding(
        title: "Approvals pending",
        detail: "\(attentionSessions.count) sessions are waiting for a tool approval.",
        severity: .warning,
        sessionIds: attentionSessions.map(\.id)
      ))
    }

    if overview.pendingSessionCount > 0 {
      findings.append(SessionInvestigationFinding(
        title: "Sessions launching",
        detail: "\(overview.pendingSessionCount) sessions are still starting.",
        severity: .info
      ))
    }

    let cleanupActions = cleanupCandidates(from: snapshot)
    let mergeActions = mergeVerificationCandidates(from: snapshot)
    let attentionActions = attentionSessions.map { session in
      SessionInvestigationAction(
        title: "Resolve approval in \(session.displayName)",
        detail: "Review the pending \(session.currentTool ?? "tool") approval before archiving or deleting this worktree.",
        category: .needsAttention,
        confidence: .high,
        provider: session.provider,
        sessionIds: [session.id],
        projectPath: session.projectPath,
        worktreePath: session.worktreePath
      )
    }

    if !cleanupActions.isEmpty {
      findings.append(SessionInvestigationFinding(
        title: "Cleanup candidates",
        detail: "\(cleanupActions.count) worktrees look idle enough to review for deletion.",
        severity: .info,
        worktreePath: cleanupActions.first?.worktreePath
      ))
    }

    let narrative = """
    AgentHub found \(overview.sessionCount) sessions across \(overview.repositoryCount) repositories. \(overview.workingSessionCount) look active or launching, \(overview.awaitingApprovalSessionCount) need approval, and \(overview.worktreeCount) worktrees are tracked. Merge and deletion decisions still need git verification before any destructive cleanup.
    """

    return SessionInvestigationReport(
      generatedAt: snapshot.generatedAt,
      source: .deterministicFallback,
      overview: overview,
      narrative: narrative,
      findings: findings,
      actions: attentionActions + cleanupActions + mergeActions,
      rawModelOutput: rawModelOutput
    )
  }

  private static func cleanupCandidates(from snapshot: SessionInvestigationSnapshot) -> [SessionInvestigationAction] {
    let activeWorktreePaths = Set(
      snapshot.sessions
        .filter { $0.isActive || $0.isAwaitingApproval }
        .compactMap(\.worktreePath)
    )
    let pendingWorktreePaths = Set(snapshot.pendingSessions.map(\.worktreePath))

    return snapshot.worktrees
      .filter(\.isWorktree)
      .filter { worktree in
        worktree.activeSessionCount == 0
          && !activeWorktreePaths.contains(worktree.path)
          && !pendingWorktreePaths.contains(worktree.path)
      }
      .map { worktree in
        let confidence: SessionInvestigationConfidence = worktree.sessionCount == 0 ? .medium : .low
        let detail: String
        if worktree.sessionCount == 0 {
          detail = "No sessions are attached to this tracked worktree. Verify git status and branch merge state, then delete it if it is no longer needed."
        } else {
          detail = "This worktree has no active sessions. Review its latest session output and git status before deleting it."
        }
        return SessionInvestigationAction(
          title: "Review \(worktree.name) for deletion",
          detail: detail,
          category: .deleteWorktreeCandidate,
          confidence: confidence,
          projectPath: worktree.repositoryPath,
          worktreePath: worktree.path
        )
      }
  }

  private static func mergeVerificationCandidates(from snapshot: SessionInvestigationSnapshot) -> [SessionInvestigationAction] {
    snapshot.sessions
      .filter { !$0.isActive && !$0.isAwaitingApproval && $0.branchName != nil }
      .prefix(6)
      .map { session in
        SessionInvestigationAction(
          title: "Verify \(session.branchName ?? session.displayName) before merge",
          detail: "The session is idle on a named branch. Check the diff, tests, and branch merge state before treating it as mergeable or merged.",
          category: .mergeCandidate,
          confidence: .low,
          provider: session.provider,
          sessionIds: [session.id],
          projectPath: session.projectPath,
          worktreePath: session.worktreePath
        )
      }
  }
}

public enum SessionInvestigationMCPUIResourceBuilder {
  public static func makeResource(
    report: SessionInvestigationReport,
    snapshot: SessionInvestigationSnapshot
  ) -> AgentHubMCPUIResource {
    AgentHubMCPUIResource(
      uri: "ui://agenthub/session-investigation/\(report.id.uuidString)",
      text: makeHTML(report: report, snapshot: snapshot)
    )
  }

  private static func makeHTML(
    report: SessionInvestigationReport,
    snapshot: SessionInvestigationSnapshot
  ) -> String {
    let actions = report.actions.isEmpty
      ? "<p class=\"muted\">No actions were recommended.</p>"
      : report.actions.map(actionHTML).joined(separator: "\n")
    let findings = report.findings.isEmpty
      ? "<p class=\"muted\">No findings were produced.</p>"
      : report.findings.map(findingHTML).joined(separator: "\n")
    let source = report.source == .claude ? "Claude investigation" : "Local fallback"
    let generated = ISO8601DateFormatter().string(from: report.generatedAt)

    return """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        :root {
          color-scheme: light dark;
          --bg: #f7f7f5;
          --panel: #ffffff;
          --text: #202124;
          --muted: #666a70;
          --line: #deded8;
          --accent: #2f6fed;
          --good: #188038;
          --warn: #b05a00;
          --critical: #c5221f;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #111214;
            --panel: #1b1c20;
            --text: #f3f4f5;
            --muted: #a7abb1;
            --line: #303238;
            --accent: #7aa7ff;
            --good: #81c995;
            --warn: #fdd663;
            --critical: #f28b82;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          padding: 24px;
          background: var(--bg);
          color: var(--text);
          font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        header {
          display: flex;
          justify-content: space-between;
          gap: 16px;
          align-items: flex-start;
          margin-bottom: 18px;
        }
        h1 {
          font-size: 22px;
          line-height: 1.2;
          margin: 0 0 6px;
          letter-spacing: 0;
        }
        h2 {
          font-size: 14px;
          margin: 0 0 10px;
          letter-spacing: 0;
        }
        .muted { color: var(--muted); }
        .badge {
          border: 1px solid var(--line);
          border-radius: 999px;
          padding: 5px 8px;
          white-space: nowrap;
          color: var(--muted);
        }
        .grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(118px, 1fr));
          gap: 10px;
          margin-bottom: 16px;
        }
        .metric, .section, .item {
          background: var(--panel);
          border: 1px solid var(--line);
          border-radius: 8px;
        }
        .metric { padding: 12px; }
        .metric strong {
          display: block;
          font-size: 22px;
          line-height: 1;
          margin-bottom: 6px;
        }
        .metric span { color: var(--muted); }
        .section {
          padding: 14px;
          margin-top: 12px;
        }
        .item {
          padding: 12px;
          margin-top: 8px;
        }
        .item-title {
          display: flex;
          align-items: center;
          gap: 8px;
          font-weight: 650;
          margin-bottom: 5px;
        }
        .dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: var(--accent);
          flex: 0 0 auto;
        }
        .warning .dot { background: var(--warn); }
        .critical .dot { background: var(--critical); }
        .deleteWorktreeCandidate .dot { background: var(--warn); }
        .merged .dot { background: var(--good); }
        .needsAttention .dot { background: var(--critical); }
        .meta {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          margin-top: 8px;
          color: var(--muted);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 11px;
        }
        .meta span {
          border: 1px solid var(--line);
          border-radius: 5px;
          padding: 3px 5px;
        }
      </style>
    </head>
    <body>
      <header>
        <div>
          <h1>Session Investigation</h1>
          <div class="muted">\(escape(source)) · \(escape(generated)) · \(snapshot.sessions.count) session records</div>
        </div>
        <div class="badge">MCP UI Resource</div>
      </header>

      <div class="grid">
        \(metricHTML("Repos", report.overview.repositoryCount))
        \(metricHTML("Worktrees", report.overview.worktreeCount))
        \(metricHTML("Sessions", report.overview.sessionCount))
        \(metricHTML("Active", report.overview.activeSessionCount))
        \(metricHTML("Monitored", report.overview.monitoredSessionCount))
        \(metricHTML("Approvals", report.overview.awaitingApprovalSessionCount))
      </div>

      <section class="section">
        <h2>Report</h2>
        <p>\(escape(report.narrative))</p>
      </section>

      <section class="section">
        <h2>Recommended Actions</h2>
        \(actions)
      </section>

      <section class="section">
        <h2>Findings</h2>
        \(findings)
      </section>
    </body>
    </html>
    """
  }

  private static func metricHTML(_ label: String, _ value: Int) -> String {
    """
    <div class="metric">
      <strong>\(value)</strong>
      <span>\(escape(label))</span>
    </div>
    """
  }

  private static func findingHTML(_ finding: SessionInvestigationFinding) -> String {
    """
    <article class="item \(escape(finding.severity.rawValue))">
      <div class="item-title"><span class="dot"></span>\(escape(finding.title))</div>
      <div>\(escape(finding.detail))</div>
      \(metadataHTML(provider: finding.provider, sessionIds: finding.sessionIds, projectPath: finding.projectPath, worktreePath: finding.worktreePath))
    </article>
    """
  }

  private static func actionHTML(_ action: SessionInvestigationAction) -> String {
    """
    <article class="item \(escape(action.category.rawValue))">
      <div class="item-title"><span class="dot"></span>\(escape(action.title))</div>
      <div>\(escape(action.detail))</div>
      \(metadataHTML(provider: action.provider, sessionIds: action.sessionIds, projectPath: action.projectPath, worktreePath: action.worktreePath, extra: [action.category.rawValue, action.confidence.rawValue]))
    </article>
    """
  }

  private static func metadataHTML(
    provider: SessionProviderKind?,
    sessionIds: [String],
    projectPath: String?,
    worktreePath: String?,
    extra: [String] = []
  ) -> String {
    var parts = extra
    if let provider {
      parts.append(provider.rawValue)
    }
    parts.append(contentsOf: sessionIds.map { "session \($0.prefix(8))" })
    if let worktreePath {
      parts.append(worktreePath)
    } else if let projectPath {
      parts.append(projectPath)
    }
    guard !parts.isEmpty else { return "" }
    return "<div class=\"meta\">" + parts.map { "<span>\(escape($0))</span>" }.joined() + "</div>"
  }

  private static func escape(_ text: String) -> String {
    AgentHubMCPUIHTML.escape(text)
  }
}
