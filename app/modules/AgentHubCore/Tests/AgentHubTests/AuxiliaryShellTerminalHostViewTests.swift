import AppKit
import Testing

@testable import AgentHubCore

@Suite("Auxiliary shell terminal host view")
struct AuxiliaryShellTerminalHostViewTests {

  @Test("Mounting a different terminal replaces the current terminal view")
  @MainActor
  func mountReplacesMountedTerminal() {
    let hostView = AuxiliaryShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let firstTerminal = TerminalContainerView()
    let secondTerminal = TerminalContainerView()

    hostView.mount(firstTerminal, key: "session-a")
    hostView.mount(secondTerminal, key: "session-b")

    #expect(hostView.subviews.count == 1)
    #expect(hostView.subviews.first === secondTerminal)
    #expect(firstTerminal.superview == nil)
    #expect(hostView.mountedTerminalKey == "session-b")
  }

  @Test("Remounting a cached terminal restores the same terminal instance")
  @MainActor
  func remountRestoresCachedTerminal() {
    let hostView = AuxiliaryShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let firstTerminal = TerminalContainerView()
    let secondTerminal = TerminalContainerView()

    hostView.mount(firstTerminal, key: "session-a")
    hostView.mount(secondTerminal, key: "session-b")
    hostView.mount(firstTerminal, key: "session-a")

    #expect(hostView.subviews.count == 1)
    #expect(hostView.subviews.first === firstTerminal)
    #expect(secondTerminal.superview == nil)
    #expect(hostView.mountedTerminalKey == "session-a")
  }

  @Test("Unmount removes the currently mounted terminal")
  @MainActor
  func unmountRemovesTerminal() {
    let hostView = AuxiliaryShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let terminal = TerminalContainerView()

    hostView.mount(terminal, key: "session-a")
    hostView.unmountTerminal()

    #expect(hostView.subviews.isEmpty)
    #expect(terminal.superview == nil)
    #expect(hostView.mountedTerminalKey == nil)
  }
}
