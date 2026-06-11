import Foundation

/// Tails the launched app's stdout log file and delivers complete lines.
///
/// Hot-reload launches use `simctl launch --stdout=<path>` instead of a
/// blocking `--console-pty` process: simctl forwards signals to the app, so
/// keeping a console process around would mean killing the user's app
/// whenever AgentHub stops or quits. A redirected file plus a kqueue
/// `DispatchSource` with byte-offset incremental reads (the same pattern as
/// the session watchers) has no such hazard and nothing to clean up.
public protocol HotReloadConsoleTailing: AnyObject {
  /// Starts tailing `path`, replacing any previous tail. The file is created
  /// empty if missing (simctl truncates it on launch). `onLine` is delivered
  /// on the main queue, once per complete line.
  func start(path: String, onLine: @escaping (String) -> Void)
  func stop()
}

public final class HotReloadConsoleTail: HotReloadConsoleTailing {

  private var source: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private var offset: UInt64 = 0
  private var partialLine = Data()
  private var onLine: ((String) -> Void)?

  public init() {}

  deinit {
    stop()
  }

  public func start(path: String, onLine: @escaping (String) -> Void) {
    stop()
    self.onLine = onLine

    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    fileDescriptor = open(path, O_EVTONLY)
    guard fileDescriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .extend],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      self?.drain(path: path)
    }
    source.setCancelHandler { [fileDescriptor] in
      close(fileDescriptor)
    }
    self.source = source
    source.resume()
    drain(path: path)
  }

  public func stop() {
    source?.cancel()
    source = nil
    fileDescriptor = -1
    offset = 0
    partialLine.removeAll()
    onLine = nil
  }

  private func drain(path: String) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return }
    defer { try? handle.close() }

    let size = (try? handle.seekToEnd()) ?? 0
    if size < offset {
      // simctl truncated the file for a new launch — start over.
      offset = 0
      partialLine.removeAll()
    }
    guard size > offset else { return }

    try? handle.seek(toOffset: offset)
    guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
    offset += UInt64(data.count)

    partialLine.append(data)
    deliverCompleteLines()
  }

  private func deliverCompleteLines() {
    while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
      let lineData = partialLine[partialLine.startIndex..<newline]
      partialLine = Data(partialLine[partialLine.index(after: newline)...])
      if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
        onLine?(line)
      }
    }
  }
}
