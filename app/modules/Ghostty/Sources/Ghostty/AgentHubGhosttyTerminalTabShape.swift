//
//  AgentHubGhosttyTerminalTabShape.swift
//  AgentHub
//

import SwiftUI

struct AgentHubGhosttyTerminalTabShape: Shape {
  let roundsTopLeading: Bool

  func path(in rect: CGRect) -> Path {
    guard roundsTopLeading else {
      return Path(rect)
    }

    let radius = min(
      AgentHubGhosttyTerminalTabChrome.firstTabCornerRadius,
      rect.width,
      rect.height
    )

    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}
