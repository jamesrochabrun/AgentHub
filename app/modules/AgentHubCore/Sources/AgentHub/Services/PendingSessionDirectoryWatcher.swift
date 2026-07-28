//
//  PendingSessionDirectoryWatcher.swift
//  AgentHub
//

import Foundation

/// One-shot kqueue watch for a new `.jsonl` session file appearing in a
/// Claude project directory.
///
/// Owns the directory descriptor for the duration of the wait and guarantees
/// it is closed on every exit path — a new file appearing, `cancel()` (user
/// dismissed the pending session card, or another resolution path won), or
/// deallocation. Previously this watch was inlined with no teardown path, so
/// every abandoned pending session permanently leaked one directory fd.
public final class PendingSessionDirectoryWatcher: @unchecked Sendable {

  public enum Outcome: Equatable, Sendable {
    /// A new `.jsonl` file appeared; the associated value is its filename.
    case found(String)
    /// `cancel()` won before any file appeared.
    case cancelled
    /// The directory could not be opened for watching.
    case unableToWatch
  }

  private let queue = DispatchQueue(label: "com.agenthub.pending-session-watcher")
  private var source: DispatchSourceFileSystemObject?
  private var isCancelled = false
  private var didStart = false
  private var foundFile: String?

  public init() {}

  deinit {
    queue.sync {
      isCancelled = true
      source?.cancel()
    }
  }

  /// Suspends until a `.jsonl` file not in `existingFiles` appears in
  /// `directoryPath`, or `cancel()` is called. Call at most once per instance.
  public func waitForNewJSONLFile(
    inDirectory directoryPath: String,
    excluding existingFiles: Set<String>
  ) async -> Outcome {
    let fd = open(directoryPath, O_EVTONLY)
    guard fd >= 0 else { return .unableToWatch }

    return await withCheckedContinuation { continuation in
      queue.async {
        guard !self.isCancelled, !self.didStart else {
          close(fd)
          continuation.resume(returning: .cancelled)
          return
        }
        self.didStart = true

        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: fd,
          eventMask: [.write, .link, .attrib],
          queue: self.queue
        )
        self.source = source

        let checkForNewFile: () -> Void = { [weak self] in
          guard let self, self.foundFile == nil else { return }
          guard let currentFiles = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
            return
          }
          let newJSONLFiles = Set(currentFiles)
            .subtracting(existingFiles)
            .filter { $0.hasSuffix(".jsonl") }
          if let newFile = newJSONLFiles.first {
            self.foundFile = newFile
            source.cancel()
          }
        }

        source.setEventHandler(handler: checkForNewFile)

        // Single resume point: the cancel handler runs exactly once whether
        // the event handler found a file or cancel()/deinit tore the watch
        // down, so the continuation can never resume twice or never.
        source.setCancelHandler { [weak self] in
          close(fd)
          guard let self else {
            continuation.resume(returning: .cancelled)
            return
          }
          self.source = nil
          if let file = self.foundFile {
            continuation.resume(returning: .found(file))
          } else {
            continuation.resume(returning: .cancelled)
          }
        }

        source.resume()

        // The file may have appeared between the caller's directory snapshot
        // and the source arming; kqueue only reports subsequent changes.
        checkForNewFile()
      }
    }
  }

  /// Ends the wait with `.cancelled` and releases the directory descriptor.
  /// Safe to call from any thread, before or after the wait starts.
  public func cancel() {
    queue.async {
      self.isCancelled = true
      self.source?.cancel()
    }
  }
}
