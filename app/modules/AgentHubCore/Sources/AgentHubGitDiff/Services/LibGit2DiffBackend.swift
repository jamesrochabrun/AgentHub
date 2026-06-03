import CLibgit2
import Foundation

enum LibGit2DiffBackend {
  private static let limitedContextReason = "Large file rendered with changed hunks only."
  private static let initializeLibrary: Void = {
    _ = git_libgit2_init()
  }()

  static func findGitRoot(at path: String) throws -> String {
    Self.initialize()

    let repo = try openRepository(at: path)
    defer { git_repository_free(repo) }

    guard let workdir = git_repository_workdir(repo) else {
      throw GitDiffError.notAGitRepository(path)
    }

    return URL(fileURLWithPath: String(cString: workdir))
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  static func detectBaseBranch(at path: String) throws -> String {
    Self.initialize()

    let repo = try openRepository(at: path)
    defer { git_repository_free(repo) }

    return try detectBaseBranch(in: repo)
  }

  /// Byte size of the repository's git index (worktree-aware: resolves the
  /// worktree-specific gitdir, so worktree checkouts report their own index).
  /// A single `stat()` — negligible cost on small repos.
  static func indexByteSize(atGitRoot gitRoot: String) -> UInt64? {
    Self.initialize()
    guard let repo = try? openRepository(at: gitRoot) else { return nil }
    defer { git_repository_free(repo) }
    guard let gitDirPointer = git_repository_path(repo) else { return nil }
    let gitDir = String(cString: gitDirPointer)
    let indexPath = (gitDir as NSString).appendingPathComponent("index")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: indexPath),
          let size = attributes[.size] as? NSNumber else {
      return nil
    }
    return size.uint64Value
  }

  /// Heuristic for whether a worktree is "large" enough that the native `git` CLI
  /// should service the index→workdir scan instead of libgit2.
  /// libgit2's `git_diff_index_to_workdir` stats every tracked file single-threaded
  /// and honors neither fsmonitor nor the untracked cache, so on monorepo-scale
  /// worktrees it is dramatically slower than native git. Index size ≈ tracked-file count.
  static func isLargeWorktree(atGitRoot gitRoot: String, thresholdBytes: UInt64) -> Bool {
    guard let size = indexByteSize(atGitRoot: gitRoot) else { return false }
    return size > thresholdBytes
  }

  static func diffAvailability(at path: String) throws -> DiffAvailabilityStatus {
    Self.initialize()

    let repo = try openRepository(at: path)
    defer { git_repository_free(repo) }

    if try hasChanges(repo: repo, mode: .unstaged, baseBranch: nil) {
      return .available
    }

    if try hasChanges(repo: repo, mode: .staged, baseBranch: nil) {
      return .available
    }

    guard let baseBranch = try? detectBaseBranch(in: repo),
          try hasChanges(repo: repo, mode: .branch, baseBranch: baseBranch) else {
      return .unavailable
    }

    return .available
  }

  static func changedFiles(
    atGitRoot gitRoot: String,
    mode: DiffMode,
    baseBranch: String?,
    renderPolicy: GitDiffRenderPolicy
  ) throws -> GitDiffState {
    Self.initialize()

    let repo = try openRepository(at: gitRoot)
    defer { git_repository_free(repo) }

    let diff = try makeDiff(
      repo: repo,
      mode: mode,
      baseBranch: baseBranch,
      paths: [],
      renderPolicy: renderPolicy,
      includeUntrackedContent: true
    )
    defer { git_diff_free(diff) }

    try findRenames(in: diff, mode: mode)

    let count = git_diff_num_deltas(diff)
    var entries: [GitDiffFileEntry] = []
    entries.reserveCapacity(count)

    for index in 0..<count {
      guard let delta = git_diff_get_delta(diff, index) else { continue }
      let stats = patchLineStats(diff: diff, index: index)
      entries.append(fileEntry(from: delta.pointee, gitRoot: gitRoot, stats: stats))
    }

    return GitDiffState(files: deduplicateEntriesById(entries))
  }

  static func renderPayload(
    for file: GitDiffFileEntry,
    atGitRoot gitRoot: String,
    mode: DiffMode,
    baseBranch: String?,
    renderPolicy: GitDiffRenderPolicy
  ) throws -> GitDiffRenderPayload {
    Self.initialize()

    let repo = try openRepository(at: gitRoot)
    defer { git_repository_free(repo) }

    let pathspec = pathspecs(for: file)
    let diff = try makeDiff(
      repo: repo,
      mode: mode,
      baseBranch: baseBranch,
      paths: pathspec,
      renderPolicy: renderPolicy,
      includeUntrackedContent: true
    )
    defer { git_diff_free(diff) }

    try findRenames(in: diff, mode: mode)

    let (patch, delta) = try makePatch(for: file, in: diff)
    defer { git_patch_free(patch) }

    if isBinary(delta.pointee) {
      throw GitDiffError.binaryFile(file.relativePath)
    }

    let maxSideSize = max(delta.pointee.old_file.size, delta.pointee.new_file.size)
    if UInt64(maxSideSize) <= renderPolicy.maxFullContentBytes,
       let fullPayload = try? fullFilePayload(
        repo: repo,
        gitRoot: gitRoot,
        file: file,
        delta: delta.pointee,
        mode: mode,
        baseBranch: baseBranch
       ) {
      return fullPayload
    }

    let patchText = try patchString(from: patch, maxPatchBytes: renderPolicy.maxPatchBytes)
    guard let payload = GitDiffPatchRenderAdapter.renderedPayload(
      from: patchText,
      limitedContextReason: limitedContextReason
    ) else {
      throw GitDiffError.binaryFile(file.relativePath)
    }

    return payload
  }
}

private extension LibGit2DiffBackend {
  static func initialize() {
    _ = initializeLibrary
  }

  static func openRepository(at path: String) throws -> OpaquePointer {
    var repo: OpaquePointer?
    let flags = UInt32(GIT_REPOSITORY_OPEN_CROSS_FS.rawValue)
    try check(git_repository_open_ext(&repo, path, flags, nil), operation: "open repository")
    guard let repo else {
      throw GitDiffError.notAGitRepository(path)
    }
    return repo
  }

  static func makeDiff(
    repo: OpaquePointer,
    mode: DiffMode,
    baseBranch: String?,
    paths: [String],
    renderPolicy: GitDiffRenderPolicy,
    includeUntrackedContent: Bool
  ) throws -> OpaquePointer {
    var options = git_diff_options()
    try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)), operation: "initialize diff options")

    var flags = UInt32(GIT_DIFF_INDENT_HEURISTIC.rawValue)
      | UInt32(GIT_DIFF_INCLUDE_TYPECHANGE.rawValue)
    if mode == .unstaged {
      flags |= UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue)
      flags |= UInt32(GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue)
      if includeUntrackedContent {
        flags |= UInt32(GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue)
      }
    }
    if !paths.isEmpty {
      flags |= UInt32(GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue)
    }
    options.flags = flags

    let cStrings = paths.map { strdup($0) }
    defer {
      for pointer in cStrings {
        free(pointer)
      }
    }

    var mutableCStringPointers = cStrings
    return try mutableCStringPointers.withUnsafeMutableBufferPointer { buffer in
      if let baseAddress = buffer.baseAddress, !paths.isEmpty {
        options.pathspec.strings = baseAddress
        options.pathspec.count = paths.count
      }

      switch mode {
      case .unstaged:
        var diff: OpaquePointer?
        try check(
          git_diff_index_to_workdir(&diff, repo, nil, &options),
          operation: "diff index to workdir"
        )
        guard let diff else {
          throw GitDiffError.gitCommandFailed("libgit2 did not return an unstaged diff")
        }
        return diff

      case .staged:
        let index = try repositoryIndex(repo)
        defer { git_index_free(index) }

        let headTree = try optionalHeadTree(repo)
        defer {
          if let headTree {
            git_tree_free(headTree)
          }
        }

        var diff: OpaquePointer?
        try check(
          git_diff_tree_to_index(&diff, repo, headTree, index, &options),
          operation: "diff tree to index"
        )
        guard let diff else {
          throw GitDiffError.gitCommandFailed("libgit2 did not return a staged diff")
        }
        return diff

      case .branch:
        let branch = try resolvedBaseBranch(baseBranch)
        let mergeBaseTree = try mergeBaseTree(repo: repo, baseBranch: branch)
        defer { git_tree_free(mergeBaseTree) }

        let headTree = try requiredHeadTree(repo)
        defer { git_tree_free(headTree) }

        var diff: OpaquePointer?
        try check(
          git_diff_tree_to_tree(&diff, repo, mergeBaseTree, headTree, &options),
          operation: "diff merge-base to HEAD"
        )
        guard let diff else {
          throw GitDiffError.gitCommandFailed("libgit2 did not return a branch diff")
        }
        return diff
      }
    }
  }

  static func hasChanges(
    repo: OpaquePointer,
    mode: DiffMode,
    baseBranch: String?
  ) throws -> Bool {
    let diff = try makeDiff(
      repo: repo,
      mode: mode,
      baseBranch: baseBranch,
      paths: [],
      renderPolicy: .default,
      includeUntrackedContent: false
    )
    defer { git_diff_free(diff) }

    return git_diff_num_deltas(diff) > 0
  }

  static func repositoryIndex(_ repo: OpaquePointer) throws -> OpaquePointer {
    var index: OpaquePointer?
    try check(git_repository_index(&index, repo), operation: "load repository index")
    guard let index else {
      throw GitDiffError.gitCommandFailed("libgit2 did not return an index")
    }
    return index
  }

  static func optionalHeadTree(_ repo: OpaquePointer) throws -> OpaquePointer? {
    do {
      return try requiredHeadTree(repo)
    } catch {
      return nil
    }
  }

  static func requiredHeadTree(_ repo: OpaquePointer) throws -> OpaquePointer {
    let commit = try commit(for: "HEAD", repo: repo)
    defer { git_commit_free(commit) }

    var tree: OpaquePointer?
    try check(git_commit_tree(&tree, commit), operation: "load HEAD tree")
    guard let tree else {
      throw GitDiffError.gitCommandFailed("libgit2 did not return HEAD tree")
    }
    return tree
  }

  static func mergeBaseTree(repo: OpaquePointer, baseBranch: String) throws -> OpaquePointer {
    let baseCommit = try commit(for: baseBranch, repo: repo)
    defer { git_commit_free(baseCommit) }

    let headCommit = try commit(for: "HEAD", repo: repo)
    defer { git_commit_free(headCommit) }

    var mergeBaseOid = git_oid()
    try withUnsafePointer(to: git_commit_id(baseCommit).pointee) { baseOid in
      try withUnsafePointer(to: git_commit_id(headCommit).pointee) { headOid in
        try check(git_merge_base(&mergeBaseOid, repo, baseOid, headOid), operation: "find merge base")
      }
    }

    var mergeBaseCommit: OpaquePointer?
    try check(git_commit_lookup(&mergeBaseCommit, repo, &mergeBaseOid), operation: "lookup merge-base commit")
    guard let mergeBaseCommit else {
      throw GitDiffError.gitCommandFailed("libgit2 did not return merge-base commit")
    }
    defer { git_commit_free(mergeBaseCommit) }

    var tree: OpaquePointer?
    try check(git_commit_tree(&tree, mergeBaseCommit), operation: "load merge-base tree")
    guard let tree else {
      throw GitDiffError.gitCommandFailed("libgit2 did not return merge-base tree")
    }
    return tree
  }

  static func commit(for spec: String, repo: OpaquePointer) throws -> OpaquePointer {
    var object: OpaquePointer?
    try check(git_revparse_single(&object, repo, spec), operation: "resolve \(spec)")
    guard let object else {
      throw GitDiffError.gitCommandFailed("libgit2 did not resolve \(spec)")
    }
    defer { git_object_free(object) }

    var commitObject: OpaquePointer?
    try check(
      git_object_peel(&commitObject, object, GIT_OBJECT_COMMIT),
      operation: "peel \(spec) to commit"
    )
    guard let commitObject else {
      throw GitDiffError.gitCommandFailed("libgit2 did not resolve \(spec) to a commit")
    }
    return commitObject
  }

  static func findRenames(in diff: OpaquePointer, mode: DiffMode) throws {
    guard git_diff_num_deltas(diff) <= 1_000 else { return }

    var options = git_diff_find_options()
    try check(
      git_diff_find_options_init(&options, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)),
      operation: "initialize rename detection"
    )
    options.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue)
      | UInt32(GIT_DIFF_FIND_RENAMES_FROM_REWRITES.rawValue)
    if mode == .unstaged {
      options.flags |= UInt32(GIT_DIFF_FIND_FOR_UNTRACKED.rawValue)
    }
    options.rename_threshold = 50
    options.rename_limit = 1_000

    try check(git_diff_find_similar(diff, &options), operation: "find renamed files")
  }

  static func makePatch(
    for file: GitDiffFileEntry,
    in diff: OpaquePointer
  ) throws -> (patch: OpaquePointer, delta: UnsafePointer<git_diff_delta>) {
    let count = git_diff_num_deltas(diff)
    for index in 0..<count {
      guard let delta = git_diff_get_delta(diff, index),
            deltaMatches(file: file, delta: delta.pointee) else {
        continue
      }

      var patch: OpaquePointer?
      try check(git_patch_from_diff(&patch, diff, index), operation: "create patch")
      guard let patch else {
        throw GitDiffError.binaryFile(file.relativePath)
      }
      return (patch, delta)
    }

    throw GitDiffError.fileNotFound(file.relativePath)
  }

  static func patchLineStats(diff: OpaquePointer, index: Int) -> (additions: Int, deletions: Int) {
    var patch: OpaquePointer?
    guard git_patch_from_diff(&patch, diff, index) == 0, let patch else {
      return (0, 0)
    }
    defer { git_patch_free(patch) }

    var additions = 0
    var deletions = 0
    guard git_patch_line_stats(nil, &additions, &deletions, patch) == 0 else {
      return (0, 0)
    }
    return (additions, deletions)
  }

  static func patchString(from patch: OpaquePointer, maxPatchBytes: UInt64) throws -> String {
    var buffer = git_buf(ptr: nil, reserved: 0, size: 0)
    try check(git_patch_to_buf(&buffer, patch), operation: "render patch")
    defer { git_buf_dispose(&buffer) }

    guard UInt64(buffer.size) <= maxPatchBytes else {
      return """
      @@ -0,0 +1,1 @@
      +Diff preview exceeds the 2 MB patch limit.
      """
    }

    guard let pointer = buffer.ptr else { return "" }
    let data = Data(bytes: pointer, count: buffer.size)
    guard let patch = String(data: data, encoding: .utf8) else {
      throw GitDiffError.binaryFile("patch")
    }
    return patch
  }

  static func fullFilePayload(
    repo: OpaquePointer,
    gitRoot: String,
    file: GitDiffFileEntry,
    delta: git_diff_delta,
    mode: DiffMode,
    baseBranch: String?
  ) throws -> GitDiffRenderPayload {
    let oldPath = file.oldRelativePath ?? file.relativePath
    let newPath = file.relativePath

    var oldContent: String
    let newContent: String

    switch mode {
    case .unstaged:
      oldContent = try contentFromIndex(repo: repo, relativePath: oldPath) ?? ""
      if delta.status == GIT_DELTA_UNTRACKED || delta.status == GIT_DELTA_ADDED {
        oldContent = ""
      }
      newContent = try contentFromWorkdir(gitRoot: gitRoot, relativePath: newPath) ?? ""

    case .staged:
      let headTree = try optionalHeadTree(repo)
      defer {
        if let headTree {
          git_tree_free(headTree)
        }
      }
      oldContent = try headTree.flatMap { try contentFromTree(repo: repo, tree: $0, relativePath: oldPath) } ?? ""
      newContent = try contentFromIndex(repo: repo, relativePath: newPath) ?? ""

    case .branch:
      let branch = try resolvedBaseBranch(baseBranch)
      let mergeBaseTree = try mergeBaseTree(repo: repo, baseBranch: branch)
      defer { git_tree_free(mergeBaseTree) }
      let headTree = try requiredHeadTree(repo)
      defer { git_tree_free(headTree) }

      oldContent = try contentFromTree(repo: repo, tree: mergeBaseTree, relativePath: oldPath) ?? ""
      newContent = try contentFromTree(repo: repo, tree: headTree, relativePath: newPath) ?? ""
    }

    return GitDiffRenderPayload(oldContent: oldContent, newContent: newContent, renderMode: .fullFile)
  }

  static func contentFromIndex(repo: OpaquePointer, relativePath: String) throws -> String? {
    let index = try repositoryIndex(repo)
    defer { git_index_free(index) }

    guard let entry = git_index_get_bypath(index, relativePath, 0) else {
      return nil
    }
    return try contentFromBlob(repo: repo, oid: entry.pointee.id)
  }

  static func contentFromTree(repo: OpaquePointer, tree: OpaquePointer, relativePath: String) throws -> String? {
    var entry: OpaquePointer?
    guard git_tree_entry_bypath(&entry, tree, relativePath) == 0, let entry else {
      return nil
    }
    defer { git_tree_entry_free(entry) }

    guard let oid = git_tree_entry_id(entry) else { return nil }
    return try contentFromBlob(repo: repo, oid: oid.pointee)
  }

  static func contentFromBlob(repo: OpaquePointer, oid: git_oid) throws -> String? {
    var mutableOid = oid
    var blob: OpaquePointer?
    try check(git_blob_lookup(&blob, repo, &mutableOid), operation: "lookup blob")
    guard let blob else { return nil }
    defer { git_blob_free(blob) }

    if git_blob_is_binary(blob) == 1 {
      throw GitDiffError.binaryFile("blob")
    }

    guard let pointer = git_blob_rawcontent(blob) else { return "" }
    let size = git_blob_rawsize(blob)
    let data = Data(bytes: pointer, count: Int(size))
    guard let content = String(data: data, encoding: .utf8) else {
      throw GitDiffError.binaryFile("blob")
    }
    return content
  }

  static func contentFromWorkdir(gitRoot: String, relativePath: String) throws -> String? {
    let path = (gitRoot as NSString).appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return try String(contentsOfFile: path, encoding: .utf8)
  }

  static func fileEntry(
    from delta: git_diff_delta,
    gitRoot: String,
    stats: (additions: Int, deletions: Int)
  ) -> GitDiffFileEntry {
    let relativePath = newPath(from: delta) ?? oldPath(from: delta) ?? ""
    let oldRelativePath = oldPath(from: delta)
    let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
    let status = status(from: delta.status)

    return GitDiffFileEntry(
      filePath: fullPath,
      relativePath: relativePath,
      oldRelativePath: oldRelativePath == relativePath ? nil : oldRelativePath,
      additions: stats.additions,
      deletions: stats.deletions,
      status: status,
      isBinary: isBinary(delta)
    )
  }

  static func status(from deltaStatus: git_delta_t) -> GitDiffFileStatus {
    switch deltaStatus {
    case GIT_DELTA_ADDED:
      return .added
    case GIT_DELTA_DELETED:
      return .deleted
    case GIT_DELTA_MODIFIED:
      return .modified
    case GIT_DELTA_RENAMED:
      return .renamed
    case GIT_DELTA_COPIED:
      return .copied
    case GIT_DELTA_UNTRACKED:
      return .untracked
    case GIT_DELTA_TYPECHANGE:
      return .typeChanged
    case GIT_DELTA_CONFLICTED:
      return .conflicted
    default:
      return .unknown
    }
  }

  static func isBinary(_ delta: git_diff_delta) -> Bool {
    let flags = delta.flags | delta.old_file.flags | delta.new_file.flags
    return (flags & UInt32(GIT_DIFF_FLAG_BINARY.rawValue)) != 0
  }

  static func oldPath(from delta: git_diff_delta) -> String? {
    string(from: delta.old_file.path)
  }

  static func newPath(from delta: git_diff_delta) -> String? {
    string(from: delta.new_file.path)
  }

  static func string(from pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
  }

  static func deltaMatches(file: GitDiffFileEntry, delta: git_diff_delta) -> Bool {
    let deltaNewPath = newPath(from: delta)
    let deltaOldPath = oldPath(from: delta)
    return deltaNewPath == file.relativePath
      || deltaOldPath == file.relativePath
      || deltaNewPath == file.oldRelativePath
      || deltaOldPath == file.oldRelativePath
  }

  static func pathspecs(for file: GitDiffFileEntry) -> [String] {
    var paths = [file.relativePath]
    if let oldRelativePath = file.oldRelativePath, oldRelativePath != file.relativePath {
      paths.append(oldRelativePath)
    }
    return paths
  }

  static func referenceExists(_ refName: String, in repo: OpaquePointer) -> Bool {
    var oid = git_oid()
    return git_reference_name_to_id(&oid, repo, refName) == 0
  }

  static func detectBaseBranch(in repo: OpaquePointer) throws -> String {
    let candidates = [
      ("refs/heads/main", "main"),
      ("refs/heads/master", "master"),
      ("refs/remotes/origin/main", "origin/main"),
      ("refs/remotes/origin/master", "origin/master"),
    ]

    for (refName, displayName) in candidates where referenceExists(refName, in: repo) {
      return displayName
    }

    throw GitDiffError.gitCommandFailed("Could not detect base branch (tried main, master, origin/main, origin/master)")
  }

  static func resolvedBaseBranch(_ baseBranch: String?) throws -> String {
    guard let baseBranch, !baseBranch.isEmpty else {
      throw GitDiffError.gitCommandFailed("Base branch is required for branch diff")
    }
    return baseBranch
  }

  static func deduplicateEntriesById(_ entries: [GitDiffFileEntry]) -> [GitDiffFileEntry] {
    var seen = Set<String>()
    var result: [GitDiffFileEntry] = []
    result.reserveCapacity(entries.count)

    for entry in entries where seen.insert(entry.id).inserted {
      result.append(entry)
    }

    return result
  }

  static func check(_ result: Int32, operation: String) throws {
    guard result < 0 else { return }
    throw GitDiffError.gitCommandFailed("libgit2 \(operation) failed: \(lastErrorMessage(fallbackCode: result))")
  }

  static func lastErrorMessage(fallbackCode: Int32) -> String {
    guard let error = git_error_last(),
          let message = error.pointee.message else {
      return "code \(fallbackCode)"
    }
    return String(cString: message)
  }
}
