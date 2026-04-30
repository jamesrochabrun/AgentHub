//
//  NativeOpenPanelPresenter.swift
//  AgentHub
//

#if canImport(AppKit)
import AppKit
import Foundation

@MainActor
enum NativeOpenPanelPresenter {
  static func present(
    configure: @escaping @MainActor (NSOpenPanel) -> Void,
    onSelection: @escaping @MainActor (URL) -> Void
  ) {
    let runLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
      MainActor.assumeIsolated {
        let panel = NSOpenPanel()
        configure(panel)

        panel.begin { response in
          guard response == .OK, let url = panel.url else { return }
          MainActor.assumeIsolated {
            onSelection(url)
          }
        }
      }
    }
    CFRunLoopWakeUp(runLoop)
  }
}
#endif
