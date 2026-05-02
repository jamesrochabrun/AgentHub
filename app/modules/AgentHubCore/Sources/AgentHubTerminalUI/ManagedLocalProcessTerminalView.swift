//
//  ManagedLocalProcessTerminalView.swift
//  AgentHub
//
//  LocalProcessTerminalView-equivalent with explicit process lifecycle control.
//

import AppKit
import Darwin
import SwiftTerm

// MARK: - FileOpenEditor

/// Preferred editor for opening files from Cmd+Click in the terminal.
public enum FileOpenEditor: Int, CaseIterable {
  /// Open in AgentHub's embedded editor (default)
  case agentHub = 0
  /// Open in VS Code
  case vscode = 1
  /// Open in Xcode
  case xcode = 2

  public var label: String {
    switch self {
    case .agentHub: return "AgentHub Editor"
    case .vscode: return "VS Code"
    case .xcode: return "Xcode"
    }
  }
}

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
  private static let fileOpenLogPrefix = "[AH-OPEN][AgentHub]"
  private static let ptyResizeDebounceInterval: TimeInterval = 0.08
  private var pendingPtyResize: (size: winsize, cols: Int, rows: Int)?
  private var pendingPtyResizeWorkItem: DispatchWorkItem?

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

  /// Tracks OSC 133 semantic prompt boundaries for this terminal.
  public let semanticPromptTracker = SemanticPromptTracker()

  /// Stores position marks for this terminal.
  public let markStore = MarkStore()

  /// Smart selection engine for context-aware text selection.
  public let smartSelectionEngine = SmartSelectionEngine()

  private func setup() {
    terminalDelegate = self
    process = LocalProcess(delegate: self)

    // Register OSC 133 handler for semantic prompt tracking
    terminal.registerOscHandler(code: 133) { [weak self] data in
      self?.semanticPromptTracker.handleOsc133(data)
    }
  }

  /// PID of the running child process, if any.
  public var currentProcessId: pid_t? {
    process.running ? process.shellPid : nil
  }

  // MARK: - TerminalViewDelegate

  public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard process.running else { return }
    pendingPtyResize = (getWindowSize(), newCols, newRows)
    pendingPtyResizeWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.flushPendingPtyResize()
    }
    pendingPtyResizeWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.ptyResizeDebounceInterval,
      execute: workItem
    )
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

  public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    Self.logFileOpen("requestOpenLink link=\"\(link)\" params=\(params)")

    if let fileLink = Self.filePathFromImplicitLink(link) {
      Self.logFileOpen("redirect implicit file link to requestOpenFile path=\"\(fileLink.path)\" line=\(fileLink.lineNumber.map(String.init) ?? "nil")")
      requestOpenFile(source: source, path: fileLink.path, lineNumber: fileLink.lineNumber)
      return
    }

    guard let url = URL(string: link), url.scheme != nil else {
      Self.logFileOpen("abort link is neither file path nor absolute URL link=\"\(link)\"")
      return
    }

    let opened = NSWorkspace.shared.open(url)
    Self.logFileOpen("dispatch=ExternalURL opened=\(opened) url=\"\(url.absoluteString)\"")
  }

  // MARK: - File Path Opening

  /// The project path for resolving relative file paths. Set by TerminalContainerView.
  public var projectPath: String?

  /// Called when user Cmd+clicks a file path. Set by parent view to route to the AgentHub editor.
  public var onOpenFile: ((String, Int?) -> Void)?

  public func requestOpenFile(source: TerminalView, path: String, lineNumber: Int?) {
    Self.logFileOpen("requestOpenFile rawPath=\"\(path)\" line=\(lineNumber.map(String.init) ?? "nil") projectPath=\"\(projectPath ?? "nil")\"")

    let resolvedPath: String
    if path.hasPrefix("/") || path.hasPrefix("~") {
      resolvedPath = (path as NSString).expandingTildeInPath
    } else if let projectPath, !projectPath.isEmpty {
      resolvedPath = (projectPath as NSString).appendingPathComponent(path)
    } else {
      resolvedPath = (NSHomeDirectory() as NSString).appendingPathComponent(path)
    }

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory)
    Self.logFileOpen("resolvedPath=\"\(resolvedPath)\" exists=\(exists) isDirectory=\(isDirectory.boolValue)")
    guard exists else {
      Self.logFileOpen("abort missing resolvedPath=\"\(resolvedPath)\"")
      return
    }

    let rawEditor = UserDefaults.standard.integer(forKey: TerminalUserDefaultsKeys.terminalFileOpenEditor)
    let editor = FileOpenEditor(
      rawValue: rawEditor
    ) ?? .agentHub
    Self.logFileOpen("editor rawValue=\(rawEditor) resolved=\(editor.label) onOpenFileSet=\(onOpenFile != nil)")

    switch editor {
    case .agentHub:
      Self.logFileOpen("dispatch=AgentHubInline path=\"\(resolvedPath)\" line=\(lineNumber.map(String.init) ?? "nil")")
      onOpenFile?(resolvedPath, lineNumber)
    case .vscode:
      Self.openInVSCode(path: resolvedPath, line: lineNumber)
    case .xcode:
      Self.openInXcode(path: resolvedPath, line: lineNumber)
    }
  }

  private static func openInVSCode(path: String, line: Int?) {
    let codePaths = [
      "/usr/local/bin/code",
      "/opt/homebrew/bin/code",
      "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    ]
    guard let codePath = codePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
      logFileOpen("VSCode not found; fallback=NSWorkspace.open opened=\(opened) path=\"\(path)\"")
      return
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: codePath)
    task.arguments = ["--goto", line != nil ? "\(path):\(line!)" : path]
    do {
      try task.run()
      logFileOpen("dispatch=VSCode executable=\"\(codePath)\" args=\(task.arguments ?? []) pid=\(task.processIdentifier)")
    } catch {
      logFileOpen("dispatch=VSCode failed executable=\"\(codePath)\" error=\"\(error.localizedDescription)\"")
    }
  }

  private static func openInXcode(path: String, line: Int?) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
    task.arguments = line != nil ? ["--line", "\(line!)", path] : [path]
    do {
      try task.run()
      logFileOpen("dispatch=Xcode executable=\"/usr/bin/xed\" args=\(task.arguments ?? []) pid=\(task.processIdentifier)")
    } catch {
      logFileOpen("dispatch=Xcode failed executable=\"/usr/bin/xed\" error=\"\(error.localizedDescription)\"")
    }
  }

  private static func logFileOpen(_ message: @autoclosure () -> String) {
    print("\(fileOpenLogPrefix) \(message())")
  }

  private static func filePathFromImplicitLink(_ link: String) -> (path: String, lineNumber: Int?)? {
    let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.contains("://"),
          URLComponents(string: trimmed)?.scheme == nil,
          trimmed.contains("/")
            || trimmed.hasPrefix("~")
            || trimmed.hasPrefix(".")
            || trimmed.hasPrefix("/")
    else {
      return nil
    }

    var path = trimmed
    var lineNumber: Int?
    if let suffixRange = path.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
      let suffix = String(path[suffixRange])
      let parts = suffix.dropFirst().split(separator: ":")
      lineNumber = parts.first.flatMap { Int($0) }
      path = String(path[..<suffixRange.lowerBound])
    }

    return path.isEmpty ? nil : (path, lineNumber)
  }

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
    cancelPendingPtyResize()
    let pid = process.shellPid
    guard pid > 0 else { return }

    if killpg(pid, SIGTERM) != 0 {
      _ = kill(pid, SIGTERM)
    }

    guard graceSeconds > 0 else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + graceSeconds) { [weak self] in
      guard let self, self.process.running else { return }
      TerminalUILogger.terminal.warning("Process group PID=\(pid) still alive; sending SIGKILL")
      _ = killpg(pid, SIGKILL)
    }
  }

  // MARK: - LocalProcessDelegate

  open func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    cancelPendingPtyResize()
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

  private func flushPendingPtyResize() {
    guard process.running,
          var pendingPtyResize
    else {
      cancelPendingPtyResize()
      return
    }

    self.pendingPtyResize = nil
    pendingPtyResizeWorkItem = nil
    let _ = PseudoTerminalHelpers.setWinSize(
      masterPtyDescriptor: process.childfd,
      windowSize: &pendingPtyResize.size
    )
    processDelegate?.sizeChanged(
      source: self,
      newCols: pendingPtyResize.cols,
      newRows: pendingPtyResize.rows
    )
  }

  private func cancelPendingPtyResize() {
    pendingPtyResizeWorkItem?.cancel()
    pendingPtyResizeWorkItem = nil
    pendingPtyResize = nil
  }
}
