//
//  BoxModelView.swift
//  AgentHub
//
//  Simple box-model visualization for the web preview inspector rail.
//

import Canvas
import SwiftUI

struct BoxModelView: View {
  let snapshot: WebPreviewLivePropertiesSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Box Model")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      ZStack {
        boxLayer(
          title: "margin",
          subtitle: snapshot.margin ?? "—",
          edges: snapshot.marginEdges,
          fill: Color.orange.opacity(0.18),
          padding: 0
        )

        boxLayer(
          title: "padding",
          subtitle: snapshot.padding ?? "—",
          edges: snapshot.paddingEdges,
          fill: Color.green.opacity(0.18),
          padding: 28
        )

        RoundedRectangle(cornerRadius: 12)
          .fill(Color.blue.opacity(0.12))
          .padding(56)
          .overlay(alignment: .center) {
            VStack(spacing: 4) {
              Text("content")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
              Text("\(snapshot.width) × \(snapshot.height)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 220)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.surfaceElevated)
    )
  }

  private func boxLayer(
    title: String,
    subtitle: String,
    edges: CSSBoxEdges,
    fill: Color,
    padding: CGFloat
  ) -> some View {
    RoundedRectangle(cornerRadius: 14)
      .fill(fill)
      .padding(padding)
      .overlay(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
          Text(subtitle)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(padding + 12)
      }
      .overlay(alignment: .top) {
        edgeLabel(edges.top)
          .padding(.top, padding + 8)
      }
      .overlay(alignment: .bottom) {
        edgeLabel(edges.bottom)
          .padding(.bottom, padding + 8)
      }
      .overlay(alignment: .leading) {
        edgeLabel(edges.left)
          .rotationEffect(.degrees(-90))
          .padding(.leading, padding + 4)
      }
      .overlay(alignment: .trailing) {
        edgeLabel(edges.right)
          .rotationEffect(.degrees(90))
          .padding(.trailing, padding + 4)
      }
  }

  private func edgeLabel(_ value: String?) -> some View {
    Text(value ?? "—")
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(.secondary)
  }
}
