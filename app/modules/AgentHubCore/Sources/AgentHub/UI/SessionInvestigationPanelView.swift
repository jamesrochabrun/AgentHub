//
//  SessionInvestigationPanelView.swift
//  AgentHub
//
//  Inline Claude-backed session investigation panel and MCP UI preview.
//

import AgentHubMCPUI
import SwiftUI

struct SessionInvestigationPanelView: View {
  @Bindable var viewModel: SessionInvestigationViewModel
  let snapshot: SessionInvestigationSnapshot
  let onClose: () -> Void

  @State private var didStart = false
  @State private var selectedMode: SessionInvestigationPanelMode = .report

  var body: some View {
    VStack(spacing: 0) {
      panelHeader

      Divider()
        .opacity(0.5)

      panelContent
    }
    .task(id: snapshot.id) {
      guard !didStart else { return }
      didStart = true
      viewModel.start(snapshot: snapshot)
    }
  }

  private var panelHeader: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 9) {
        Image(systemName: "sparkles")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.brandPrimary)
          .frame(width: 18, height: 18)

        VStack(alignment: .leading, spacing: 1) {
          Text("Investigation")
            .font(.heading)
            .foregroundStyle(.primary)

          Text(viewModel.statusMessage)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }

        Spacer()

        if viewModel.isRunning {
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.7)
        }

        Button {
          if viewModel.isRunning {
            viewModel.cancel()
          }
          onClose()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("Close investigation")
      }

      if viewModel.report != nil {
        Picker("Investigation view", selection: $selectedMode) {
          Label("Report", systemImage: "doc.text").tag(SessionInvestigationPanelMode.report)
          Label("MCP", systemImage: "rectangle.on.rectangle").tag(SessionInvestigationPanelMode.mcp)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var panelContent: some View {
    if let errorMessage = viewModel.errorMessage {
      errorView(errorMessage)
    } else if let report = viewModel.report {
      switch selectedMode {
      case .report:
        NativeSessionInvestigationReportView(report: report, metricColumnCount: 2)
          .padding(8)
      case .mcp:
        AgentHubMCPUIResourceView(
          resource: SessionInvestigationMCPUIResourceBuilder.makeResource(
            report: report,
            snapshot: snapshot
          )
        )
        .padding(8)
      }
    } else {
      loadingView
    }
  }

  private var loadingView: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("Reading local session metadata")
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func errorView(_ message: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 26))
        .foregroundStyle(.orange)
      Text("Investigation failed")
        .font(.secondaryLarge)
        .foregroundStyle(.primary)
      Text(message)
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

private enum SessionInvestigationPanelMode: Hashable {
  case report
  case mcp
}

private struct NativeSessionInvestigationReportView: View {
  let report: SessionInvestigationReport
  let metricColumnCount: Int

  init(report: SessionInvestigationReport, metricColumnCount: Int = 3) {
    self.report = report
    self.metricColumnCount = metricColumnCount
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        overviewGrid

        ReportSection(title: "Report") {
          Text(report.narrative)
            .font(.secondaryDefault)
            .foregroundColor(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        ReportSection(title: "Recommended Actions") {
          if report.actions.isEmpty {
            EmptyReportRow(text: "No actions recommended.")
          } else {
            VStack(spacing: 8) {
              ForEach(report.actions) { action in
                SessionInvestigationActionRow(action: action)
              }
            }
          }
        }

        ReportSection(title: "Findings") {
          if report.findings.isEmpty {
            EmptyReportRow(text: "No findings produced.")
          } else {
            VStack(spacing: 8) {
              ForEach(report.findings) { finding in
                SessionInvestigationFindingRow(finding: finding)
              }
            }
          }
        }

        if let rawModelOutput = report.rawModelOutput, !rawModelOutput.isEmpty {
          ReportSection(title: "Raw Output") {
            Text(rawModelOutput)
              .font(.primarySmall)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(4)
    }
  }

  private var overviewGrid: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: metricColumnCount),
      alignment: .leading,
      spacing: 10
    ) {
      MetricTile(label: "Repos", value: report.overview.repositoryCount)
      MetricTile(label: "Worktrees", value: report.overview.worktreeCount)
      MetricTile(label: "Sessions", value: report.overview.sessionCount)
      MetricTile(label: "Active", value: report.overview.activeSessionCount)
      MetricTile(label: "Monitored", value: report.overview.monitoredSessionCount)
      MetricTile(label: "Approvals", value: report.overview.awaitingApprovalSessionCount)
    }
  }
}

private struct ReportSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.heading)
        .foregroundColor(.secondary)

      content()
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }
}

private struct MetricTile: View {
  let label: String
  let value: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(value)")
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .foregroundColor(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)

      Text(label)
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }
}

private struct SessionInvestigationActionRow: View {
  let action: SessionInvestigationAction

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Circle()
          .fill(color)
          .frame(width: 8, height: 8)

        Text(action.title)
          .font(.secondaryLarge)
          .foregroundColor(.primary)

        Spacer()

        Text(action.confidence.rawValue.capitalized)
          .font(.secondaryCaption)
          .foregroundColor(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            Capsule()
              .fill(color.opacity(0.14))
          )
      }

      Text(action.detail)
        .font(.secondaryDefault)
        .foregroundColor(.secondary)
        .textSelection(.enabled)

      MetadataChips(
        provider: action.provider,
        category: action.category.rawValue,
        sessionIds: action.sessionIds,
        projectPath: action.projectPath,
        worktreePath: action.worktreePath
      )
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        .fill(Color.surfaceCanvas.opacity(0.65))
    )
  }

  private var color: Color {
    switch action.category {
    case .needsAttention:
      return .orange
    case .deleteWorktreeCandidate, .cleanup, .removeFromHub:
      return .yellow
    case .merged:
      return .green
    case .mergeCandidate:
      return .blue
    case .scale, .observe, .unknown:
      return .brandPrimary
    }
  }
}

private struct SessionInvestigationFindingRow: View {
  let finding: SessionInvestigationFinding

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Circle()
          .fill(color)
          .frame(width: 8, height: 8)

        Text(finding.title)
          .font(.secondaryLarge)
          .foregroundColor(.primary)

        Spacer()
      }

      Text(finding.detail)
        .font(.secondaryDefault)
        .foregroundColor(.secondary)
        .textSelection(.enabled)

      MetadataChips(
        provider: finding.provider,
        category: finding.severity.rawValue,
        sessionIds: finding.sessionIds,
        projectPath: finding.projectPath,
        worktreePath: finding.worktreePath
      )
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
        .fill(Color.surfaceCanvas.opacity(0.65))
    )
  }

  private var color: Color {
    switch finding.severity {
    case .info:
      return .blue
    case .warning:
      return .orange
    case .critical:
      return .red
    }
  }
}

private struct MetadataChips: View {
  let provider: SessionProviderKind?
  let category: String
  let sessionIds: [String]
  let projectPath: String?
  let worktreePath: String?

  var body: some View {
    let chips = metadata
    if !chips.isEmpty {
      FlowLayout(spacing: 6) {
        ForEach(chips, id: \.self) { chip in
          Text(chip)
            .font(.primaryCaption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.surfaceOverlay)
            )
        }
      }
    }
  }

  private var metadata: [String] {
    var result = [category]
    if let provider {
      result.append(provider.rawValue)
    }
    result.append(contentsOf: sessionIds.map { String($0.prefix(8)) })
    if let worktreePath {
      result.append(worktreePath)
    } else if let projectPath {
      result.append(projectPath)
    }
    return result
  }
}

private struct EmptyReportRow: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.secondaryDefault)
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
          .fill(Color.surfaceCanvas.opacity(0.65))
      )
  }
}

private struct FlowLayout: Layout {
  let spacing: CGFloat

  init(spacing: CGFloat) {
    self.spacing = spacing
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    layout(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let result = layout(in: bounds.width, subviews: subviews)
    for item in result.items {
      subviews[item.index].place(
        at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
        proposal: ProposedViewSize(item.size)
      )
    }
  }

  private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, items: [Item]) {
    var items: [Item] = []
    var cursor = CGPoint.zero
    var rowHeight: CGFloat = 0
    let availableWidth = max(width, 1)

    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if cursor.x > 0 && cursor.x + size.width > availableWidth {
        cursor.x = 0
        cursor.y += rowHeight + spacing
        rowHeight = 0
      }

      items.append(Item(index: index, origin: cursor, size: size))
      cursor.x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    return (
      CGSize(width: availableWidth, height: cursor.y + rowHeight),
      items
    )
  }

  private struct Item {
    let index: Int
    let origin: CGPoint
    let size: CGSize
  }
}
