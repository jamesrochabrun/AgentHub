//
//  FileDescriptorLimits.swift
//  AgentHub
//

import Darwin
import Foundation

/// Raises the process open-file soft limit at launch.
///
/// GUI apps launched from Finder inherit launchd's default soft limit of 256
/// open files. AgentHub holds one descriptor per monitored session JSONL plus
/// hook sidecars, PTY masters, kqueue watchers, SQLite, and transient
/// subprocess pipes, so a busy hub can exhaust 256 — after which PTY spawns,
/// git subprocesses, and file watchers all fail until relaunch. Child shells
/// inherit the raised limit, so agents inside embedded terminals benefit too.
public enum FileDescriptorLimits {
  /// OPEN_MAX (10 240), the historical Darwin per-process ceiling. Kept below
  /// larger values because C code using select(2) misbehaves once descriptor
  /// numbers reach FD_SETSIZE-sensitive territory, and 10 240 is ample.
  public static let targetSoftLimit: rlim_t = 10_240

  /// Raises the RLIMIT_NOFILE soft limit to `targetSoftLimit`, bounded by the
  /// hard limit. Never lowers an already-higher limit. Returns the resulting
  /// soft limit, or nil when the current limit could not be read.
  @discardableResult
  public static func raiseSoftLimit() -> rlim_t? {
    var limits = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
      AppLogger.session.error("[FDLimits] getrlimit(RLIMIT_NOFILE) failed errno=\(errno)")
      return nil
    }

    let current = limits.rlim_cur
    guard current < targetSoftLimit else {
      return current
    }

    // RLIM_INFINITY (not importable from Swift) is numerically enormous, so
    // min() against the hard limit covers both the bounded and infinite cases.
    let ceiling = min(limits.rlim_max, targetSoftLimit)
    guard ceiling > current else {
      return current
    }

    limits.rlim_cur = ceiling
    guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
      AppLogger.session.error(
        "[FDLimits] setrlimit(RLIMIT_NOFILE) to \(ceiling) failed errno=\(errno); staying at \(current)"
      )
      return current
    }

    AppLogger.session.info("[FDLimits] raised open-file soft limit \(current) -> \(ceiling)")
    return ceiling
  }
}
