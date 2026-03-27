//
//  WebInspectorOverlay.swift
//  WebInspector
//
//  View modifier that adds the element inspector overlay (banner + input)
//  to any view. Works with InspectableWebView or any custom WKWebView setup.
//

import SwiftUI

// MARK: - WebInspectorOverlay

/// Adds the inspect-mode banner and floating input overlay to the modified view.
///
/// Usage:
/// ```swift
/// @State var inspectState = ElementInspectState()
///
/// InspectableWebView(url: myURL, ...)
///   .webInspectorOverlay(state: inspectState) { element, instruction in
///     let prompt = ElementInspectorPromptBuilder.buildPrompt(
///       element: element, instruction: instruction
///     )
///     // send prompt to your agent
///   }
/// ```
struct WebInspectorOverlayModifier: ViewModifier {
  @Bindable var state: ElementInspectState
  let inputPlacement: WebInspectInputPlacement
  let onSubmit: ((ElementInspectorData, String) -> Void)?
  let onContextSelection: ((ElementInspectorData) -> Void)?

  func body(content: Content) -> some View {
    ZStack {
      content

      // Top banner
      if state.isActive, !state.isInputShowing {
        VStack {
          HStack(spacing: 6) {
            Image(systemName: "cursorarrow.click.2")
              .font(.system(size: 12))
              .foregroundColor(.white)
            Text(state.isContextMode
              ? "Context Mode — click elements to capture"
              : "Inspect Mode — click any element")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(.white)
            Spacer()
            Button {
              state.deactivate()
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Exit inspect mode (Esc)")
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.85))
          Spacer()
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      // Input/context overlay
      if let element = state.selectedElement {
        Group {
          switch state.mode {
          case .input:
            WebInspectInputOverlay(
              state: state,
              placement: inputPlacement,
              onSubmit: onSubmit
            )

          case .context:
            WebInspectContextView(
              element: element,
              onDismiss: {
                state.deactivate()
              }
            )
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .animation(.easeOut(duration: 0.2), value: state.isActive)
    .animation(.easeOut(duration: 0.15), value: state.selectedElement?.id)
    .onChange(of: state.selectedElement?.id) { _, newValue in
      guard newValue != nil,
            state.isContextMode,
            let element = state.selectedElement else { return }
      onContextSelection?(element)
      state.dismissInput()
    }
  }
}

// MARK: - View Extension

public extension View {
  /// Adds the web element inspector overlay (banner + floating input) to this view.
  ///
  /// - Parameters:
  ///   - state: The shared `ElementInspectState` controlling the inspector lifecycle.
  ///   - inputPlacement: Controls where the inspect input editor is placed in input mode.
  ///   - onSubmit: Called with the selected element and the user's instruction when they press Enter (input mode).
  ///   - onContextSelection: Called with the selected element immediately on click (context mode).
  func webInspectorOverlay(
    state: ElementInspectState,
    inputPlacement: WebInspectInputPlacement = .bottom,
    onSubmit: ((ElementInspectorData, String) -> Void)? = nil,
    onContextSelection: ((ElementInspectorData) -> Void)? = nil
  ) -> some View {
    modifier(WebInspectorOverlayModifier(
      state: state,
      inputPlacement: inputPlacement,
      onSubmit: onSubmit,
      onContextSelection: onContextSelection
    ))
  }
}
