//
//  WebPreviewFileWatcher.swift
//  AgentHub
//
//  Watches a directory for file system changes (writes, renames, new files)
//  and bumps a reload token so the web preview auto-refreshes.
//

import Foundation

@MainActor
@Observable
final class WebPreviewFileWatcher {

  var reloadToken = UUID()

  private var source: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private var debounceWorkItem: DispatchWorkItem?
  private var suppressedReloadsUntil: Date?

  func watch(directory: String) {
    stop()

    let fd = open(directory, O_EVTONLY)
    guard fd >= 0 else {
      AppLogger.devServer.error("[FileWatcher] Could not open directory for watching: \(directory)")
      return
    }
    fileDescriptor = fd

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .attrib, .link],
      queue: DispatchQueue.global(qos: .utility)
    )

    source.setEventHandler { [weak self] in
      self?.scheduleReload()
    }

    source.setCancelHandler { [fd] in
      close(fd)
    }

    source.resume()
    self.source = source
    AppLogger.devServer.info("[FileWatcher] Watching directory: \(directory)")
  }

  func stop() {
    debounceWorkItem?.cancel()
    debounceWorkItem = nil
    source?.cancel()
    source = nil
    fileDescriptor = -1
    suppressedReloadsUntil = nil
  }

  func suppressReloads(for duration: TimeInterval) {
    guard duration > 0 else { return }
    suppressReloads(until: Date().addingTimeInterval(duration))
  }

  func suppressReloads(until date: Date) {
    if let suppressedReloadsUntil, suppressedReloadsUntil >= date { return }
    suppressedReloadsUntil = date
  }

  func isReloadSuppressed(at date: Date = Date()) -> Bool {
    guard let suppressedReloadsUntil else { return false }
    if suppressedReloadsUntil > date { return true }
    self.suppressedReloadsUntil = nil
    return false
  }

  deinit {
    MainActor.assumeIsolated {
      debounceWorkItem?.cancel()
      source?.cancel()
      // fd is closed by the cancel handler
    }
  }

  // MARK: - Private

  private func scheduleReload() {
    debounceWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      DispatchQueue.main.async {
        guard let self, !self.isReloadSuppressed() else { return }
        self.reloadToken = UUID()
      }
    }
    debounceWorkItem = work
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
  }
}
