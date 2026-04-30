//
//  ProjectLandingView.swift
//  AgentHub
//

import SwiftUI

struct ProjectLandingView: View {
  let projectName: String
  let projectPath: String
  let onStartSession: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    VStack(spacing: 16) {
      ZStack {
        Circle()
          .fill(Color.primary.opacity(0.1))
          .frame(width: 86, height: 86)

        Image(systemName: "folder.badge.plus")
          .font(.system(size: 34, weight: .regular))
          .foregroundColor(.primary.opacity(0.9))
      }

      VStack(spacing: 7) {
        Text(projectName)
          .font(.system(size: 24, weight: .semibold, design: .monospaced))
          .foregroundColor(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)

        Text(projectPath)
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 520)
      }

      Button(action: onStartSession) {
        HStack(spacing: 8) {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 13))
          Text("Start New Session")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(colorScheme == .dark ? .black : .white)
        .frame(height: 38)
        .padding(.horizontal, 22)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary)
        )
        .shadow(color: Color.primary.opacity(0.28), radius: 7, y: 3)
      }
      .buttonStyle(.plain)
      .padding(.top, 2)
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(backgroundColor)
  }

  private var backgroundColor: some View {
    if runtimeTheme?.hasCustomBackgrounds == true {
      Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    } else {
      colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.96)
    }
  }
}
