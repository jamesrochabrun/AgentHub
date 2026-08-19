import AgentHubCLIKit
import Canvas
import Foundation
import Observation

/// What the library needs from SQLite. `SessionMetadataStore` conforms.
public protocol StudioPersisting: Sendable {
  func saveStudioArtifact(_ record: StudioArtifactRecord) async throws
  func getStudioArtifacts(forProjectPath projectPath: String) async throws -> [StudioArtifactRecord]
  func getAllStudioArtifacts() async throws -> [StudioArtifactRecord]
  func deleteStudioArtifact(id: String) async throws
  func deleteAllStudioArtifacts(forProjectPath projectPath: String) async throws
}

/// The Studio panel's model — every artifact filed for every project, shared by
/// the Claude and Codex view models.
///
/// Keyed by **project**, never by session: a design canvas outlives the
/// conversation that produced it, and every session working on the project sees
/// the same set. Both provider view models write into one instance, so a canvas
/// filed from Codex is on screen for a Claude session in the same repo.
///
/// Storage discipline: SQLite is the source of truth; the served document under
/// `documents.rootURL` is a cache rewritten from the payload whenever it is
/// missing. Overwrite in place, delete cascades, reconcile on launch.
@MainActor
@Observable
public final class StudioLibrary {
  public private(set) var artifactsByProject: [String: [StudioArtifact]] = [:]
  private var loadedProjectKeys: Set<String> = []
  private var loadingProjectKeys: Set<String> = []

  @ObservationIgnored private let persistence: (any StudioPersisting)?
  @ObservationIgnored private let documents: any StudioDocumentWriting
  @ObservationIgnored private let server: any StudioStaticServing
  @ObservationIgnored private let index: StudioIndexStore

  public init(
    persistence: (any StudioPersisting)?,
    documents: any StudioDocumentWriting = StudioDocumentWriter(),
    server: (any StudioStaticServing)? = nil,
    index: StudioIndexStore = StudioIndexStore()
  ) {
    self.persistence = persistence
    self.documents = documents
    self.server = server ?? StudioStaticServer(rootURL: documents.rootURL)
    self.index = index
  }

  // MARK: - Reading

  public func artifacts(forProjectKey key: String) -> [StudioArtifact] {
    artifactsByProject[key] ?? []
  }

  public func artifact(id: String, projectKey key: String) -> StudioArtifact? {
    artifactsByProject[key]?.first { $0.id == id }
  }

  /// The file the static server serves for an artifact.
  public func documentURL(for artifact: StudioArtifact, projectKey key: String) -> URL {
    documents.documentURL(forArtifactId: artifact.id, projectKey: key)
  }

  /// The localhost URL for an artifact, starting the server on first use and
  /// rewriting the document if the cache is missing or from an older host page.
  public func servedURL(for artifact: StudioArtifact, projectKey key: String) async -> URL? {
    ensureDocumentIsCurrent(artifact, projectKey: key)
    do {
      let base = try await server.start()
      let relative = documents.relativePath(forArtifactId: artifact.id, projectKey: key)
      return URL(string: relative, relativeTo: base)?.absoluteURL
    } catch {
      AppLogger.session.error("Studio server failed to start: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Writing

  /// Takes an artifact filed by the CLI. In-memory first so the button appears
  /// immediately, then disk and SQLite. Returns the artifact as stored (with
  /// its resolved revision) so callers that produced it can recognise it.
  @discardableResult
  public func store(
    _ artifact: StudioArtifact,
    projectKey key: String,
    sessionId: String,
    aliasPaths: [String]
  ) async -> StudioArtifact {
    let existing = artifactsByProject[key] ?? []
    let resolved = existing.first { $0.id == artifact.id }.map { artifact.replacing($0) } ?? artifact
    artifactsByProject[key] = Self.merged(existing: existing, incoming: [resolved])

    do {
      _ = try documents.write(resolved, projectKey: key)
    } catch {
      AppLogger.session.error("Failed to write studio document \(resolved.id): \(error.localizedDescription)")
    }
    publishIndex(forKey: key, aliasPaths: aliasPaths)

    guard let persistence else { return resolved }
    do {
      try await persistence.saveStudioArtifact(
        StudioArtifactRecord(artifact: resolved, projectPath: key, sessionId: sessionId)
      )
    } catch {
      AppLogger.session.error("Failed to save studio artifact: \(error.localizedDescription)")
    }
    return resolved
  }

  /// Bakes Edit-mode changes into a canvas: replaces the named variants' `html`
  /// with the serialized artboard markup (inline styles and text the user
  /// applied) and re-stores. Studio is a scratch surface — what the user sees
  /// is what the variant becomes, and Implement/Promote sends exactly this.
  @discardableResult
  public func updateVariantHTML(
    artifactId: String,
    htmlByVariant: [String: String],
    projectKey key: String,
    sessionId: String,
    aliasPaths: [String]
  ) async -> StudioArtifact? {
    guard let artifact = artifact(id: artifactId, projectKey: key), artifact.kind == .canvas else { return nil }
    let variants = artifact.variants.map { variant -> StudioVariant in
      guard let html = htmlByVariant[variant.name] else { return variant }
      return StudioVariant(
        name: variant.name,
        html: html,
        css: variant.css,
        notes: variant.notes,
        width: variant.width,
        height: variant.height
      )
    }
    guard variants != artifact.variants else { return artifact }
    return await store(artifact.withVariants(variants), projectKey: key, sessionId: sessionId, aliasPaths: aliasPaths)
  }

  /// Reads a project's persisted artifacts back once. Merges rather than
  /// replaces: an artifact can arrive from the queue before this completes.
  public func load(projectKey key: String, aliasPaths: [String]) async {
    guard let persistence, !loadedProjectKeys.contains(key), loadingProjectKeys.insert(key).inserted else { return }
    defer { loadingProjectKeys.remove(key) }

    do {
      let records = try await persistence.getStudioArtifacts(forProjectPath: key)
      loadedProjectKeys.insert(key)
      let decoded = records.compactMap { try? $0.decodedArtifact() }
      guard !decoded.isEmpty else { return }
      artifactsByProject[key] = Self.merged(existing: artifactsByProject[key] ?? [], incoming: decoded)
      publishIndex(forKey: key, aliasPaths: aliasPaths)
    } catch {
      AppLogger.session.error("Failed to load studio artifacts: \(error.localizedDescription)")
    }
  }

  public func delete(id: String, projectKey key: String, aliasPaths: [String]) async {
    artifactsByProject[key]?.removeAll { $0.id == id }
    if artifactsByProject[key]?.isEmpty == true {
      artifactsByProject.removeValue(forKey: key)
    }
    publishIndex(forKey: key, aliasPaths: aliasPaths)
    try? documents.delete(artifactId: id, projectKey: key)

    guard let persistence else { return }
    do {
      try await persistence.deleteStudioArtifact(id: id)
    } catch {
      AppLogger.session.error("Failed to delete studio artifact: \(error.localizedDescription)")
    }
  }

  /// Removes everything for a project — Settings only.
  public func deleteAll(projectKey key: String) async {
    artifactsByProject.removeValue(forKey: key)
    loadedProjectKeys.remove(key)
    publishIndex(forKey: key, aliasPaths: [])
    try? documents.deleteAll(projectKey: key)

    guard let persistence else { return }
    do {
      try await persistence.deleteAllStudioArtifacts(forProjectPath: key)
    } catch {
      AppLogger.session.error("Failed to delete studio artifacts for project: \(error.localizedDescription)")
    }
  }

  // MARK: - Tweaks

  public enum TweakDefaultsError: LocalizedError, Equatable {
    case unknownArtifact
    case unknownProp(String)
    case documentEditFailed(String)

    public var errorDescription: String? {
      switch self {
      case .unknownArtifact: return "The artifact is no longer available."
      case .unknownProp(let name): return "The canvas has no prop named \(name)."
      case .documentEditFailed(let reason): return "Couldn't rewrite the document's dc_set_props call: \(reason)"
      }
    }
  }

  /// Makes the panel's current tweak values the artifact's defaults and
  /// re-stores it (revision bump, so the open panel reloads with them).
  ///
  /// Canvas: the shared `props` schema is updated in the payload — the host
  /// page is regenerated from it. Document: the `dc_set_props` call in the
  /// stored HTML is spliced with `TweakPropsSourceEditor` (parser-verified) —
  /// never a full-file rewrite. Neither path touches the served cache directly;
  /// both go through `store`, so SQLite stays the source of truth.
  public func saveTweakDefaults(
    artifactId: String,
    values: [String: TweakPropValue],
    projectKey key: String,
    sessionId: String,
    aliasPaths: [String]
  ) async throws {
    guard let artifact = artifact(id: artifactId, projectKey: key) else {
      throw TweakDefaultsError.unknownArtifact
    }

    let updated: StudioArtifact
    switch artifact.kind {
    case .canvas:
      var props = artifact.props
      for (name, value) in values {
        guard let index = props.firstIndex(where: { $0.name == name }) else {
          throw TweakDefaultsError.unknownProp(name)
        }
        props[index] = props[index].withValue(Self.studioValue(value))
      }
      updated = artifact.withContent(props: props)
    case .document:
      var html = artifact.html ?? ""
      for (name, value) in values.sorted(by: { $0.key < $1.key }) {
        do {
          html = try TweakPropsSourceEditor.applyingValueEdit(propName: name, newValue: value, toSource: html)
        } catch {
          throw TweakDefaultsError.documentEditFailed("\(error)")
        }
      }
      updated = artifact.withContent(html: html)
    }

    // `store` re-anchors on the existing id: createdAt is kept, revision bumps.
    await store(updated, projectKey: key, sessionId: sessionId, aliasPaths: aliasPaths)
  }

  static func studioValue(_ value: TweakPropValue) -> StudioTweakValue {
    switch value {
    case .number(let number): return .number(number)
    case .string(let string): return .string(string)
    case .boolean(let flag): return .boolean(flag)
    }
  }

  // MARK: - Settings / lifecycle

  public struct ProjectSummary: Identifiable, Equatable, Sendable {
    public var id: String { projectKey }
    public let projectKey: String
    public let artifacts: [StudioArtifact]
    public let bytesOnDisk: Int64
  }

  /// Every stored artifact grouped by project, including projects no longer
  /// open in the sidebar, with the bytes each occupies on disk.
  public func allProjects() async -> [ProjectSummary] {
    guard let persistence else { return [] }
    let records = (try? await persistence.getAllStudioArtifacts()) ?? []
    var grouped: [String: [StudioArtifact]] = [:]
    for record in records {
      guard let artifact = try? record.decodedArtifact() else { continue }
      grouped[record.projectPath, default: []].append(artifact)
    }
    return grouped
      .map { key, artifacts in
        let bytes = artifacts.reduce(Int64(0)) { total, artifact in
          total + StudioStorageReconciler.directorySize(
            at: documents.documentURL(forArtifactId: artifact.id, projectKey: key).deletingLastPathComponent()
          )
        }
        return ProjectSummary(projectKey: key, artifacts: Self.merged(existing: [], incoming: artifacts), bytesOnDisk: bytes)
      }
      .sorted { $0.projectKey < $1.projectKey }
  }

  /// Drops served-document directories that no row vouches for. Call once at launch.
  public func reconcileStorage() async {
    guard let persistence else { return }
    let records = (try? await persistence.getAllStudioArtifacts()) ?? []
    let known = Set(records.map { StudioDocumentWriter.artifactDirectoryName(forId: $0.id) })
    let root = documents.rootURL
    _ = await Task.detached(priority: .utility) {
      StudioStorageReconciler(rootURL: root).reconcile(knownDirectoryNames: known)
    }.value
  }

  // MARK: - Helpers

  private func ensureDocumentIsCurrent(_ artifact: StudioArtifact, projectKey key: String) {
    guard !documents.isCurrent(artifact, projectKey: key) else { return }
    do {
      _ = try documents.write(artifact, projectKey: key)
    } catch {
      AppLogger.session.error("Failed to rewrite studio document \(artifact.id): \(error.localizedDescription)")
    }
  }

  /// Republishes the agent-readable index for a project. This is how
  /// `agenthub_list_artifacts` sees anything: the CLI never opens the database.
  private func publishIndex(forKey key: String, aliasPaths: [String]) {
    let entries = (artifactsByProject[key] ?? []).map { artifact in
      let documentURL = documents.documentURL(forArtifactId: artifact.id, projectKey: key)
      return StudioIndexEntry(
        artifact: artifact,
        documentPath: documentURL.path,
        payloadPath: StudioDocumentWriter.payloadURL(besideDocument: documentURL).path
      )
    }
    let index = StudioIndex(projectPath: key, updatedAt: .now, artifacts: entries)
    let store = self.index
    Task.detached(priority: .utility) {
      do {
        try store.write(index, aliasPaths: aliasPaths)
      } catch {
        AppLogger.session.error("Failed to publish studio index: \(error.localizedDescription)")
      }
    }
  }

  /// Union by id, newest-filed first. Incoming wins on collision.
  static func merged(existing: [StudioArtifact], incoming: [StudioArtifact]) -> [StudioArtifact] {
    let incomingIds = Set(incoming.map(\.id))
    return (incoming + existing.filter { !incomingIds.contains($0.id) })
      .sorted {
        if $0.createdAt == $1.createdAt { return $0.id > $1.id }
        return $0.createdAt > $1.createdAt
      }
  }
}
