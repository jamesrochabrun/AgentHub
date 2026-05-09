//
//  NSSplitViewAutosaveDisabler.swift
//  AgentHub
//

import AppKit
import SwiftUI

struct NSSplitViewAutosaveDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> ProbeView {
    ProbeView()
  }

  func updateNSView(_ nsView: ProbeView, context: Context) {
    nsView.disableAutosaveSoon()
  }

  @discardableResult
  static func disableNearestSplitViewAutosave(from view: NSView) -> NSSplitView? {
    guard let splitView = nearestSplitView(from: view) else { return nil }
    splitView.autosaveName = nil
    return splitView
  }

  static func nearestSplitView(from view: NSView) -> NSSplitView? {
    var candidate: NSView? = view
    while let current = candidate {
      if let splitView = current as? NSSplitView {
        return splitView
      }
      candidate = current.superview
    }
    return nil
  }

  final class ProbeView: NSView {
    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      disableAutosaveSoon()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disableAutosaveSoon()
    }

    func disableAutosaveSoon() {
      NSSplitViewAutosaveDisabler.disableNearestSplitViewAutosave(from: self)
      Task { @MainActor [weak self] in
        guard let self else { return }
        NSSplitViewAutosaveDisabler.disableNearestSplitViewAutosave(from: self)
      }
    }
  }
}
