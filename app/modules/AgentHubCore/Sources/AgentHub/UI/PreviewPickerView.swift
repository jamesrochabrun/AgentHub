//
//  PreviewPickerView.swift
//  AgentHub
//
//  Lists discovered #Preview declarations grouped by source file.
//

import SwiftUI
import SwiftUIPreviewKit

struct PreviewPickerView: View {
  let previews: [PreviewDeclaration]
  let selected: PreviewDeclaration?
  let onSelect: (PreviewDeclaration) -> Void

  private var groupedByFile: [(fileName: String, items: [PreviewDeclaration])] {
    let grouped = Dictionary(grouping: previews, by: \.fileName)
    return grouped
      .sorted { $0.key < $1.key }
      .map { (fileName: $0.key, items: $0.value) }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(groupedByFile, id: \.fileName) { group in
          Section {
            ForEach(group.items) { preview in
              previewRow(preview)
            }
          } header: {
            Text(group.fileName)
              .font(.caption2)
              .fontWeight(.semibold)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)
              .padding(.top, 8)
              .padding(.bottom, 2)
          }
        }
      }
      .padding(.vertical, 8)
    }
  }

  private func previewRow(_ preview: PreviewDeclaration) -> some View {
    Button(action: { onSelect(preview) }) {
      HStack(spacing: 8) {
        Image(systemName: "eye")
          .font(.caption2)
          .foregroundStyle(preview == selected ? .primary : .tertiary)
        VStack(alignment: .leading, spacing: 1) {
          Text(preview.displayName)
            .font(.caption)
            .fontWeight(preview == selected ? .semibold : .regular)
          Text("Line \(preview.lineNumber)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if preview == selected {
          Image(systemName: "checkmark")
            .font(.caption2)
            .foregroundStyle(.blue)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(preview == selected ? Color.accentColor.opacity(0.08) : Color.clear)
    .cornerRadius(4)
    .padding(.horizontal, 4)
  }
}
