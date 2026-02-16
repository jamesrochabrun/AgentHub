//
//  ThemeEnvironment.swift
//  AgentHub
//
//  SwiftUI environment integration for runtime themes
//

import SwiftUI

private struct ThemeEnvironmentKey: EnvironmentKey {
  static let defaultValue: RuntimeTheme? = nil
}

extension EnvironmentValues {
  public var runtimeTheme: RuntimeTheme? {
    get { self[ThemeEnvironmentKey.self] }
    set { self[ThemeEnvironmentKey.self] = newValue }
  }
}

extension View {
  public func runtimeTheme(_ theme: RuntimeTheme) -> some View {
    environment(\.runtimeTheme, theme)
  }
}
