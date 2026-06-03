//
//  DiffBench — benchmarks GitDiffService against a real repository/worktree.
//  Usage:  swift run --package-path app/modules/AgentHubCore -c release DiffBench [path]
//  Always run with -c release; debug builds skew the numbers.
//

import Foundation
import AgentHubGitDiff

func pad(_ value: String, _ width: Int) -> String {
  value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
}
func timed<T>(_ body: () async -> T) async -> (milliseconds: Double, value: T) {
  let start = Date(); let value = await body()
  return (Date().timeIntervalSince(start) * 1000, value)
}
func row(_ label: String, _ ms: Double, _ detail: String = "") {
  print("\(pad(label, 16)) \(pad(String(format: "%.0f ms", ms), 11)) \(detail)")
}
func fileCount(_ state: GitDiffState?) -> Int { state?.files.count ?? -1 }

let path = CommandLine.arguments.count > 1
  ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
print("DiffBench — \(path)\n")

print("changedFiles: BEFORE (force libgit2)  →  AFTER (gated)")
for mode in DiffMode.allCases {
  let before = GitDiffService(largeWorktreeIndexByteThreshold: .max)
  let after = GitDiffService()
  let (b, bState) = await timed { try? await before.changedFiles(at: path, mode: mode, baseBranch: nil) }
  let (a, aState) = await timed { try? await after.changedFiles(at: path, mode: mode, baseBranch: nil) }
  let speedup = b > 0 && a > 0 ? String(format: "%.1fx", b / a) : "-"
  let files = fileCount(aState) >= 0 ? fileCount(aState) : fileCount(bState)
  row(mode.rawValue, a, "(before \(String(format: "%.0f", b))ms → after \(String(format: "%.0f", a))ms, \(speedup); files=\(files))")
}

print("\nServices (gated, cold)")
let (avMs, av) = await timed { await DiffAvailabilityService.shared.availability(for: path) }
row("availability", avMs, "(\(av))")
let (sMs, sum) = await timed { await LocalDiffSummaryService.shared.summary(for: path) }
row("summary", sMs, "(files=\(sum.fileCount) +\(sum.additions)/-\(sum.deletions))")
