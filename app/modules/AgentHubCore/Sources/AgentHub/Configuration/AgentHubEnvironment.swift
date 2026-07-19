//
//  AgentHubEnvironment.swift
//  AgentHub
//
//  SwiftUI environment integration for AgentHub
//

import SwiftUI

// MARK: - Environment Key

private struct AgentHubProviderKey: EnvironmentKey {
  static let defaultValue: AgentHubProvider? = nil
}

extension EnvironmentValues {
  /// Access to the AgentHub provider from the environment
  ///
  /// Use this to access AgentHub services from any view in the hierarchy.
  ///
  /// ## Example
  /// ```swift
  /// struct MyView: View {
  ///   @Environment(\.agentHub) private var agentHub
  ///
  ///   var body: some View {
  ///     if let provider = agentHub {
  ///       Text("Tokens: \(provider.statsService.formattedTotalTokens)")
  ///     }
  ///   }
  /// }
  /// ```
  public var agentHub: AgentHubProvider? {
    get { self[AgentHubProviderKey.self] }
    set { self[AgentHubProviderKey.self] = newValue }
  }
}

// MARK: - View Modifier

/// View modifier that injects AgentHub provider into the environment
///
/// Intentionally not `private`: this modifier is part of the window's root view
/// type, and SwiftUI derives the `NSWindow Frame` / `NSSplitView Subview Frames`
/// autosave defaults keys from that type's name. A `private` type's runtime name
/// embeds an ASLR-dependent `(unknown context at $…)` discriminator, which mints
/// a new dead defaults key every launch and bloats the app's defaults domain
/// until CFPrefs work hangs the main thread.
struct AgentHubModifier: ViewModifier {
  let provider: AgentHubProvider
  let themeManager: ThemeManager

  init(provider: AgentHubProvider) {
    self.provider = provider
    self.themeManager = provider.themeManager
  }

  func body(content: Content) -> some View {
    content
      .environment(\.agentHub, provider)
      .environment(provider.statsService)
      .environment(provider.displaySettings)
      .environment(provider.worktreeGenerationProgressCoordinator)
      .environment(themeManager)
      .environment(\.runtimeTheme, themeManager.currentTheme)
  }
}

extension View {
  /// Configures the view hierarchy with an AgentHub provider
  ///
  /// Use this modifier at the root of your view hierarchy to make
  /// AgentHub services available to all child views.
  ///
  /// ## Example
  /// ```swift
  /// @State private var provider = AgentHubProvider()
  ///
  /// var body: some Scene {
  ///   WindowGroup {
  ///     ContentView()
  ///       .agentHub(provider)
  ///   }
  /// }
  /// ```
  ///
  /// - Parameter provider: The AgentHub provider to inject
  /// - Returns: A view with AgentHub configured in the environment
  public func agentHub(_ provider: AgentHubProvider) -> some View {
    modifier(AgentHubModifier(provider: provider))
  }

  /// Configures the view hierarchy with a default AgentHub provider
  ///
  /// Creates a new `AgentHubProvider` with default configuration.
  /// For most cases, prefer passing an explicit provider to share
  /// state across windows/scenes.
  ///
  /// - Returns: A view with AgentHub configured in the environment
  public func agentHub() -> some View {
    modifier(AgentHubModifier(provider: AgentHubProvider()))
  }

  /// Configures the view hierarchy with a custom AgentHub configuration
  ///
  /// Creates a new `AgentHubProvider` with the specified configuration.
  ///
  /// - Parameter configuration: Custom configuration for AgentHub
  /// - Returns: A view with AgentHub configured in the environment
  public func agentHub(configuration: AgentHubConfiguration) -> some View {
    modifier(AgentHubModifier(provider: AgentHubProvider(configuration: configuration)))
  }
}
