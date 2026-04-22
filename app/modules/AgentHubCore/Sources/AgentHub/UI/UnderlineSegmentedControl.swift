//
//  UnderlineSegmentedControl.swift
//  AgentHub
//

import SwiftUI

struct UnderlineSegmentedControl<Content: View>: View {
  let tint: Color
  let content: Content
  let spacing: CGFloat
  let fillsAvailableWidth: Bool

  init(
    tint: Color,
    spacing: CGFloat = 16,
    fillsAvailableWidth: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.tint = tint
    self.spacing = spacing
    self.fillsAvailableWidth = fillsAvailableWidth
    self.content = content()
  }

  var body: some View {
    if fillsAvailableWidth {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: spacing) {
          content
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Rectangle()
          .fill(tint)
          .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
      }
    } else {
      HStack(spacing: spacing) {
        content
      }
      .padding(.bottom, 2)
      .overlay(alignment: .bottomLeading) {
        Rectangle()
          .fill(tint)
          .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
      }
      .fixedSize(horizontal: true, vertical: false)
    }
  }
}
