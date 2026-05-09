import AppKit
import Testing

@testable import AgentHubCore

@MainActor
@Suite("NSSplitViewAutosaveDisabler")
struct NSSplitViewAutosaveDisablerTests {
  @Test("Clears nearest ancestor split view autosave name")
  func clearsNearestAncestorAutosaveName() {
    let splitView = NSSplitView()
    splitView.autosaveName = NSSplitView.AutosaveName("com.agenthub.test.split")

    let sidebar = NSView()
    let detail = NSView()
    let probe = NSView()

    splitView.addArrangedSubview(sidebar)
    splitView.addArrangedSubview(detail)
    detail.addSubview(probe)

    let disabledSplitView = NSSplitViewAutosaveDisabler.disableNearestSplitViewAutosave(from: probe)

    #expect(disabledSplitView === splitView)
    #expect(splitView.autosaveName == nil)
  }

  @Test("Does nothing when there is no ancestor split view")
  func doesNothingWithoutAncestorSplitView() {
    let root = NSView()
    let probe = NSView()
    root.addSubview(probe)

    let disabledSplitView = NSSplitViewAutosaveDisabler.disableNearestSplitViewAutosave(from: probe)

    #expect(disabledSplitView == nil)
  }
}
