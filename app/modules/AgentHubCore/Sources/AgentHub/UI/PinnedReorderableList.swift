//
//  PinnedReorderableList.swift
//  AgentHub
//

import SwiftUI

/// Hosts the sidebar's pinned rows with drag-to-reorder: grab a row anywhere,
/// the others slide aside, drop.
///
/// This is a plain `VStack` rather than a nested `List`, because the sidebar
/// already owns the surrounding scroll view. Each row is a native macOS drop
/// destination, and its upper/lower half selects whether the dragged row lands
/// before or after it. The midpoint threshold keeps the order stable while
/// rows animate around the pointer.
///
/// The floating drag image — not the in-place row — carries the theme-color
/// treatment (translucent fill, border, glow), via the `onDrag` custom
/// preview. The in-place row is left untouched so the styling reads as "the
/// thing in your hand", not "the slot it came from".
struct PinnedReorderableList<Item: Identifiable, Row: View>: View where Item.ID == String {
  let items: [Item]
  let onMove: (String, String, PinnedSessionDropPlacement) -> Void
  let onDrop: () -> Void
  @ViewBuilder let row: (Item) -> Row

  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var draggingID: String?
  @State private var rowHeights: [String: Double] = [:]
  /// Measured list width. The drag preview renders offscreen with no width
  /// proposal, and rows are `maxWidth: .infinity`, so the preview must be
  /// pinned to the width the row actually renders at in the sidebar.
  @State private var rowWidth: CGFloat = 0

  private var accent: Color { Color.brandPrimary(from: runtimeTheme) }

  init(
    items: [Item],
    onMove: @escaping (String, String, PinnedSessionDropPlacement) -> Void,
    onDrop: @escaping () -> Void,
    @ViewBuilder row: @escaping (Item) -> Row
  ) {
    self.items = items
    self.onMove = onMove
    self.onDrop = onDrop
    self.row = row
  }

  var body: some View {
    VStack(spacing: 2) {
      ForEach(items) { item in
        row(item)
          .onDrag {
            draggingID = item.id
            return NSItemProvider(object: item.id as NSString)
          } preview: {
            DraggedRowPreview(accent: accent, width: rowWidth) {
              row(item)
            }
          }
          .background {
            GeometryReader { proxy in
              Color.clear.preference(
                key: PinnedRowHeightPreferenceKey.self,
                value: [item.id: Double(proxy.size.height)]
              )
            }
          }
          .onDrop(
            of: [.text],
            delegate: PinnedRowDropDelegate(
              targetID: item.id,
              targetHeight: rowHeights[item.id] ?? 0,
              draggingID: $draggingID,
              onMove: onMove,
              onDrop: onDrop
            )
          )
          .id(item.id)
      }
    }
    .onPreferenceChange(PinnedRowHeightPreferenceKey.self) { heights in
      rowHeights = heights
    }
    .background {
      GeometryReader { proxy in
        Color.clear
          .onAppear { rowWidth = proxy.size.width }
          .onChange(of: proxy.size.width) { _, width in
            rowWidth = width
          }
      }
    }
  }
}

// MARK: - DraggedRowPreview

/// The floating drag image: the row itself, dressed in the theme color — a
/// translucent fill, a border, and a glow cast by that border. The shadow
/// lives on the stroke shape (shadowing the content would outline every text
/// glyph), and the padding gives the glow room inside the snapshot bounds so
/// it is not clipped at the image edge.
private struct DraggedRowPreview<Content: View>: View {
  let accent: Color
  let width: CGFloat
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(width: width > 0 ? width : nil)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(accent.opacity(0.15))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(accent.opacity(0.8), lineWidth: 1)
          .shadow(color: accent.opacity(0.5), radius: 4)
      )
      .padding(6)
  }
}

// MARK: - PinnedRowDropDelegate

/// Reorders against a stable before/after threshold within one row.
///
/// `dropExited` intentionally does not clear the drag identity: the same drag
/// must remain valid when the pointer leaves the list and comes back.
private struct PinnedRowDropDelegate: DropDelegate {
  let targetID: String
  let targetHeight: Double
  @Binding var draggingID: String?
  let onMove: (String, String, PinnedSessionDropPlacement) -> Void
  let onDrop: () -> Void

  func dropEntered(info: DropInfo) {
    updateOrder(info: info)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    updateOrder(info: info)
    return DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard acceptsDrop(info) else { return false }
    updateOrder(info: info)
    draggingID = nil
    onDrop()
    return true
  }

  func validateDrop(info: DropInfo) -> Bool {
    acceptsDrop(info)
  }

  private func acceptsDrop(_ info: DropInfo) -> Bool {
    draggingID != nil && info.hasItemsConforming(to: [.text])
  }

  private func updateOrder(info: DropInfo) {
    guard
      acceptsDrop(info),
      let draggingID,
      draggingID != targetID
    else { return }

    // Preferences normally provide the exact height before a drag can begin.
    // Keep a sensible fallback so a drag started during the first layout pass
    // still reorders instead of silently doing nothing.
    let midpoint = targetHeight > 0 ? targetHeight / 2 : 22
    let placement: PinnedSessionDropPlacement =
      Double(info.location.y) < midpoint ? .before : .after
    onMove(draggingID, targetID, placement)
  }
}

private struct PinnedRowHeightPreferenceKey: PreferenceKey {
  static let defaultValue: [String: Double] = [:]

  static func reduce(
    value: inout [String: Double],
    nextValue: () -> [String: Double]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}
