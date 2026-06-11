//
//  HotReloadStatusPillView.swift
//  AgentHub
//
//  The "● Hot reload" status pill in the simulator panel header — a pure
//  status light. Hot reload and the preview host are always armed for
//  launches started from the panel (no toggles); the pill mirrors
//  `HotReloadMonitor.phase` truthfully, pulsing while a reload or fallback
//  rebuild is in flight and never claiming a swap that didn't happen.
//

import SimulatorPreview
import SwiftUI

struct HotReloadStatusPillView: View {
  let phase: HotReloadPhase
  let warning: String?

  var body: some View {
    HStack(spacing: 5) {
      PulsingDotView(color: dotColor, isPulsing: isPulsing)
      Text(label)
        .font(.caption.weight(.medium))
        .foregroundStyle(labelStyle)
        .lineLimit(1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(Color.secondary.opacity(0.12)))
    .fixedSize()
    .help(helpText)
    .accessibilityLabel("Hot reload status: \(label)")
  }

  private var label: String {
    switch phase {
    case .disabled: return "Not armed"
    case .preparing: return "Preparing…"
    case .idle: return "Hot reload on"
    case .reloading: return "Reloading…"
    case .reloaded: return "Reloaded"
    case .rebuilding: return "Rebuilding…"
    case .failed: return "Reload failed"
    case .unavailable: return "Hot reload off"
    }
  }

  private var dotColor: Color {
    switch phase {
    case .disabled, .unavailable: return .secondary.opacity(0.5)
    case .preparing: return .secondary
    case .idle, .reloading, .reloaded: return .green
    case .rebuilding: return .orange
    case .failed: return .red
    }
  }

  private var labelStyle: Color {
    switch phase {
    case .disabled, .unavailable, .preparing: return .secondary
    default: return .primary
    }
  }

  private var isPulsing: Bool {
    switch phase {
    case .preparing, .reloading, .rebuilding: return true
    default: return false
    }
  }

  private var statusDetail: String {
    switch phase {
    case .disabled: return "Build & Run from this panel to arm hot reload"
    case .preparing(let detail): return detail
    case .idle: return "Armed — save a Swift file to hot-swap it"
    case .reloading(let fileName): return "Injecting \(fileName)…"
    case .reloaded(let summary): return summary
    case .rebuilding(let reason): return "Rebuilding: \(reason)"
    case .failed(let message): return message
    case .unavailable(let reason): return reason
    }
  }

  private var helpText: String {
    if let warning { return "\(statusDetail)\n⚠︎ \(warning)" }
    return statusDetail
  }
}

/// Status dot that softly pulses while work is in flight.
private struct PulsingDotView: View {
  let color: Color
  let isPulsing: Bool

  @State private var dimmed = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 7, height: 7)
      .opacity(dimmed ? 0.3 : 1)
      .onChange(of: isPulsing, initial: true) { _, pulsing in
        if pulsing {
          withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            dimmed = true
          }
        } else {
          withAnimation(.easeOut(duration: 0.2)) {
            dimmed = false
          }
        }
      }
  }
}
