//
//  ElementTreeView.swift
//  AgentHub
//
//  Displays the selected element's local DOM neighborhood.
//

import Canvas
import SwiftUI

struct ElementTreeView: View {
  let children: ElementRelationships
  let siblings: ElementRelationships

  @State private var showsChildren = true
  @State private var showsSiblings = true

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("DOM Context")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      relationshipSection(
        title: "Children",
        count: children.count,
        items: children.items,
        isExpanded: $showsChildren
      )

      relationshipSection(
        title: "Siblings",
        count: siblings.count,
        items: siblings.items,
        isExpanded: $showsSiblings
      )
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.surfaceElevated)
    )
  }

  private func relationshipSection(
    title: String,
    count: Int,
    items: [ElementSummary],
    isExpanded: Binding<Bool>
  ) -> some View {
    DisclosureGroup(isExpanded: isExpanded) {
      if items.isEmpty {
        Text("No nearby elements captured.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(items.enumerated()), id: \.offset) { pair in
            let item = pair.element
            VStack(alignment: .leading, spacing: 2) {
              Text(summaryText(for: item))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
              if !item.textContent.isEmpty {
                Text(item.textContent)
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.top, 6)
      }
    } label: {
      HStack {
        Text(title)
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Text("\(count)")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func summaryText(for item: ElementSummary) -> String {
    var pieces = [item.tagName.lowercased()]
    if !item.elementId.isEmpty {
      pieces.append("#\(item.elementId)")
    }
    if !item.className.isEmpty {
      pieces.append(".\(item.className.replacingOccurrences(of: " ", with: "."))")
    }
    return pieces.joined(separator: "")
  }
}
