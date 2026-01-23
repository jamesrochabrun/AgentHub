//
//  ManagedLocalProcessTerminalView.swift
//  AgentHub
//
//  LocalProcessTerminalView-equivalent with explicit process lifecycle control.
//

import AppKit
import Darwin
import SwiftTerm

/// Delegate for ManagedLocalProcessTerminalView process events.
public protocol ManagedLocalProcessTerminalViewDelegate: AnyObject {
  func sizeChanged(source: ManagedLocalProcessTerminalView, newCols: Int, newRows: Int)
  func setTerminalTitle(source: ManagedLocalProcessTerminalView, title: String)
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
  func processTerminated(source: TerminalView, exitCode: Int32?)
}

/// Local-process terminal view with explicit process control.
open class ManagedLocalProcessTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
  private var process: LocalProcess!

  /// Delegate for process-related events.
  public weak var processDelegate: ManagedLocalProcessTerminalViewDelegate?

  public override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    terminalDelegate = self
    process = LocalProcess(delegate: self)
  }

  /// PID of the running child process, if any.
  public var currentProcessId: pid_t? {
    process.running ? process.shellPid : nil
  }

  // MARK: - TerminalViewDelegate

  public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard process.running else { return }
    var size = getWindowSize()
    let _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    processDelegate?.sizeChanged(source: self, newCols: newCols, newRows: newRows)
  }

  public func clipboardCopy(source: TerminalView, content: Data) {
    if let str = String(bytes: content, encoding: .utf8) {
      let pasteBoard = NSPasteboard.general
      pasteBoard.clearContents()
      pasteBoard.writeObjects([str as NSString])
    }
  }

  public func setTerminalTitle(source: TerminalView, title: String) {
    processDelegate?.setTerminalTitle(source: self, title: title)
  }

  public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    processDelegate?.hostCurrentDirectoryUpdate(source: source, directory: directory)
  }

  open func send(source: TerminalView, data: ArraySlice<UInt8>) {
    process.send(data: data)
  }

  public func setHostLogging(directory: String?) {
    process.setHostLogging(directory: directory)
  }

  open func scrolled(source: TerminalView, position: Double) {}

  open func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

  // MARK: - Process Control

  public func startProcess(
    executable: String = "/bin/bash",
    args: [String] = [],
    environment: [String]? = nil,
    execName: String? = nil
  ) {
    process.startProcess(
      executable: executable,
      args: args,
      environment: environment,
      execName: execName
    )
  }

  /// Terminates the process group for the running child.
  public func terminateProcessTree(graceSeconds: TimeInterval = 1.0) {
    guard process.running else { return }
    let pid = process.shellPid
    guard pid > 0 else { return }

    if killpg(pid, SIGTERM) != 0 {
      _ = kill(pid, SIGTERM)
    }

    guard graceSeconds > 0 else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + graceSeconds) { [weak self] in
      guard let self, self.process.running else { return }
      AppLogger.session.warning("Process group PID=\(pid) still alive; sending SIGKILL")
      _ = killpg(pid, SIGKILL)
    }
  }

  // MARK: - LocalProcessDelegate

  open func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    processDelegate?.processTerminated(source: self, exitCode: exitCode)
  }

  open func dataReceived(slice: ArraySlice<UInt8>) {
    feed(byteArray: slice)
  }

  open func getWindowSize() -> winsize {
    let f: CGRect = frame
    return winsize(
      ws_row: UInt16(terminal.rows),
      ws_col: UInt16(terminal.cols),
      ws_xpixel: UInt16(f.width),
      ws_ypixel: UInt16(f.height)
    )
  }
}
