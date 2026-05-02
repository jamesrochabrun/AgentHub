//
//  TerminalSplitLayoutTree.swift
//  AgentHub
//

import CoreGraphics
import SwiftUI

public indirect enum TerminalSplitLayoutTree<ID: Hashable>: Equatable where ID: Equatable {
  case pane(ID)
  case split(axis: TerminalWorkspaceSplitAxis, children: [TerminalSplitLayoutTree<ID>])

  public var paneIDs: [ID] {
    switch self {
    case .pane(let id):
      return [id]
    case .split(_, let children):
      return children.flatMap(\.paneIDs)
    }
  }
}

public enum TerminalSplitFrameCalculator {
  public static func frames<ID: Hashable>(
    for tree: TerminalSplitLayoutTree<ID>,
    in rect: CGRect,
    dividerSize: CGFloat = 1
  ) -> [ID: CGRect] {
    switch tree {
    case .pane(let id):
      return [id: rect]
    case .split(let axis, let children):
      return splitFrames(axis: axis, children: children, in: rect, dividerSize: dividerSize)
    }
  }

  private static func splitFrames<ID: Hashable>(
    axis: TerminalWorkspaceSplitAxis,
    children: [TerminalSplitLayoutTree<ID>],
    in rect: CGRect,
    dividerSize: CGFloat
  ) -> [ID: CGRect] {
    guard !children.isEmpty else { return [:] }

    var result: [ID: CGRect] = [:]
    let childCount = CGFloat(children.count)

    switch axis {
    case .vertical:
      let totalDividerWidth = dividerSize * CGFloat(max(children.count - 1, 0))
      let childWidth = max(0, rect.width - totalDividerWidth) / childCount
      var nextX = rect.minX

      for (index, child) in children.enumerated() {
        if index > 0 {
          nextX += dividerSize
        }
        let childRect = CGRect(x: nextX, y: rect.minY, width: childWidth, height: rect.height)
        result.merge(
          frames(for: child, in: childRect, dividerSize: dividerSize),
          uniquingKeysWith: { current, _ in current }
        )
        nextX += childWidth
      }

    case .horizontal:
      let totalDividerHeight = dividerSize * CGFloat(max(children.count - 1, 0))
      let childHeight = max(0, rect.height - totalDividerHeight) / childCount
      var nextY = rect.minY

      for (index, child) in children.enumerated() {
        if index > 0 {
          nextY += dividerSize
        }
        let childRect = CGRect(x: rect.minX, y: nextY, width: rect.width, height: childHeight)
        result.merge(
          frames(for: child, in: childRect, dividerSize: dividerSize),
          uniquingKeysWith: { current, _ in current }
        )
        nextY += childHeight
      }
    }

    return result
  }
}

public struct TerminalSplitTreeView<ID: Hashable, Content: View>: View {
  private let tree: TerminalSplitLayoutTree<ID>
  private let dividerSize: CGFloat
  private let content: (ID) -> Content

  public init(
    tree: TerminalSplitLayoutTree<ID>,
    dividerSize: CGFloat = 1,
    @ViewBuilder content: @escaping (ID) -> Content
  ) {
    self.tree = tree
    self.dividerSize = dividerSize
    self.content = content
  }

  public var body: some View {
    layoutView(for: tree)
  }

  private func layoutView(for node: TerminalSplitLayoutTree<ID>) -> AnyView {
    switch node {
    case .pane(let id):
      AnyView(content(id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      )
    case .split(let axis, let children):
      splitView(axis: axis, children: children)
    }
  }

  private func splitView(axis: TerminalWorkspaceSplitAxis, children: [TerminalSplitLayoutTree<ID>]) -> AnyView {
    AnyView(GeometryReader { proxy in
      let childCount = max(children.count, 1)
      switch axis {
      case .vertical:
        let totalDividerWidth = dividerSize * CGFloat(max(children.count - 1, 0))
        let childWidth = max(0, proxy.size.width - totalDividerWidth) / CGFloat(childCount)
        HStack(spacing: 0) {
          ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
            if offset > 0 {
              divider(axis: axis)
            }
            layoutView(for: child)
              .frame(width: childWidth, height: proxy.size.height)
          }
        }
      case .horizontal:
        let totalDividerHeight = dividerSize * CGFloat(max(children.count - 1, 0))
        let childHeight = max(0, proxy.size.height - totalDividerHeight) / CGFloat(childCount)
        VStack(spacing: 0) {
          ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
            if offset > 0 {
              divider(axis: axis)
            }
            layoutView(for: child)
              .frame(width: proxy.size.width, height: childHeight)
          }
        }
      }
    })
  }

  @ViewBuilder
  private func divider(axis: TerminalWorkspaceSplitAxis) -> some View {
    switch axis {
    case .vertical:
      Color.primary.opacity(0.35)
        .frame(width: dividerSize)
    case .horizontal:
      Color.primary.opacity(0.35)
        .frame(height: dividerSize)
    }
  }
}
