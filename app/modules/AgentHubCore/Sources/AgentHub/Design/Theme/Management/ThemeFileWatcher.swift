//
//  ThemeFileWatcher.swift
//  AgentHub
//
//  File watcher for hot-reloading theme files
//

import Foundation

public final class ThemeFileWatcher {
  private var sources: [URL: DispatchSourceFileSystemObject] = [:]

  public init() {}

  public func watch(fileURL: URL, onChange: @escaping () -> Void) {
    // Stop watching if already watching this file
    stopWatching(fileURL: fileURL)

    let fileDescriptor = open(fileURL.path, O_EVTONLY)
    guard fileDescriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .delete],
      queue: .main
    )

    source.setEventHandler {
      onChange()
    }

    source.setCancelHandler {
      close(fileDescriptor)
    }

    source.resume()
    sources[fileURL] = source
  }

  public func stopWatching(fileURL: URL) {
    sources[fileURL]?.cancel()
    sources.removeValue(forKey: fileURL)
  }

  deinit {
    sources.values.forEach { $0.cancel() }
  }
}
