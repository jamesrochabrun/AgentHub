import Foundation

/// What kind of surface a Studio artifact renders on.
public enum StudioArtifactKind: String, Codable, Equatable, Sendable {
  /// One self-contained HTML document, served verbatim (`agenthub_artifact`).
  case document
  /// N fragments of one component laid out on an infinite canvas (`agenthub_design`).
  case canvas
}

/// One variant on a design canvas.
///
/// `html` and `css` are stored *normalized* — the fragment the agent sent with
/// document wrappers and scripts stripped and its `<style>` blocks hoisted into
/// `css` — but never *scoped*: scoping is an artefact of sharing one document,
/// applied at write time. Promotion sends these fields, so they must stay the
/// agent's own markup.
public struct StudioVariant: Codable, Equatable, Sendable {
  public let name: String
  public let html: String
  public let css: String
  public let notes: String?
  public let width: Double?
  public let height: Double?

  public init(
    name: String,
    html: String,
    css: String = "",
    notes: String? = nil,
    width: Double? = nil,
    height: Double? = nil
  ) {
    self.name = name
    self.html = html
    self.css = css
    self.notes = notes
    self.width = width
    self.height = height
  }
}

/// A single artifact an agent filed into the Studio panel — the unit the panel renders.
///
/// The agent renders into a scratch surface, never into the project: nothing in
/// this record points at, or is written to, the user's repository.
public struct StudioArtifact: Codable, Equatable, Identifiable, Sendable {
  /// Caps on how much a single artifact may carry.
  ///
  /// These are guardrails: the artifact is persisted and served from disk, so an
  /// agent that dumps a 40 MB report would bloat the store and stall the panel.
  /// Exceeding a cap is a tool-level validation error the agent can see and
  /// correct — never a silent truncation, which would make a canvas misrepresent
  /// its own variant count.
  public enum Limits {
    public static let maxDocumentBytes = 1_500_000
    public static let maxVariants = 12
    public static let maxVariantBytes = 262_144
    public static let maxTitleLength = 120
    public static let maxNameLength = 40
    public static let maxNotesLength = 500
  }

  public let id: String
  public let kind: StudioArtifactKind
  /// When this artifact was first filed. Preserved across re-files so a refreshed
  /// item keeps its place in the panel instead of jumping to the top.
  public let createdAt: Date
  /// When the content was last replaced. `nil` for an artifact never re-filed.
  public let updatedAt: Date?
  /// Bumped on every re-file. Not a history — the document is overwritten in
  /// place — but the signal an open panel reloads on.
  public let revision: Int
  /// Document title, or the component name for a canvas.
  public let title: String
  /// The real component the variants explore (e.g. `src/components/Button.tsx`).
  /// Used only by Promote so the prompt can name the file; AgentHub never reads
  /// or writes it.
  public let sourcePath: String?
  /// The document, for `.document`. Served verbatim.
  public let html: String?
  /// The variants, for `.canvas`.
  public let variants: [StudioVariant]
  /// The canvas's shared tweak schema (`.canvas` only). One schema for every
  /// variant, exposed as CSS custom properties — see `StudioTweakProp`.
  public let props: [StudioTweakProp]
  /// What normalization dropped (an `@import`, an external stylesheet). Surfaced
  /// to the agent in the tool result and kept here so the panel can show them.
  public let warnings: [String]

  /// The branch the filing session was on, stamped by the app.
  public let branchName: String?

  public let sourceProvider: WorktreeLaunchProvider
  public let sourceSessionId: String?
  public let sourceProjectPath: String?
  public let sourceProcessId: Int32

  public init(
    id: String,
    kind: StudioArtifactKind,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    revision: Int = 1,
    title: String,
    sourcePath: String? = nil,
    html: String? = nil,
    variants: [StudioVariant] = [],
    props: [StudioTweakProp] = [],
    warnings: [String] = [],
    branchName: String? = nil,
    sourceProvider: WorktreeLaunchProvider,
    sourceSessionId: String?,
    sourceProjectPath: String?,
    sourceProcessId: Int32
  ) {
    self.id = id
    self.kind = kind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.revision = revision
    self.title = title
    self.sourcePath = sourcePath
    self.html = html
    self.variants = variants
    self.props = props
    self.warnings = warnings
    self.branchName = branchName
    self.sourceProvider = sourceProvider
    self.sourceSessionId = sourceSessionId
    self.sourceProjectPath = sourceProjectPath
    self.sourceProcessId = sourceProcessId
  }

  /// The timestamp to show: when the content was last replaced.
  public var displayDate: Date {
    updatedAt ?? createdAt
  }

  public var variantNames: [String] {
    variants.map(\.name)
  }

  /// Re-anchors an incoming re-file onto the artifact it replaces.
  ///
  /// The original filing date is kept (so the refreshed item holds its place),
  /// the incoming timestamp becomes the update time, and the revision advances
  /// so an open panel knows to reload.
  public func replacing(_ previous: StudioArtifact) -> StudioArtifact {
    StudioArtifact(
      id: previous.id,
      kind: kind,
      createdAt: previous.createdAt,
      updatedAt: createdAt,
      revision: previous.revision + 1,
      title: title,
      sourcePath: sourcePath ?? previous.sourcePath,
      html: html,
      variants: variants,
      props: props,
      warnings: warnings,
      branchName: branchName,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId,
      sourceProjectPath: sourceProjectPath,
      sourceProcessId: sourceProcessId
    )
  }

  /// Records which branch filed the current content. Stamped by the app, which
  /// already knows the session's branch.
  public func stamped(branchName: String?) -> StudioArtifact {
    StudioArtifact(
      id: id,
      kind: kind,
      createdAt: createdAt,
      updatedAt: updatedAt,
      revision: revision,
      title: title,
      sourcePath: sourcePath,
      html: html,
      variants: variants,
      props: props,
      warnings: warnings,
      branchName: branchName,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId,
      sourceProjectPath: sourceProjectPath,
      sourceProcessId: sourceProcessId
    )
  }

  /// The artifact with replaced content (html and/or props), keeping identity
  /// and provenance — what Save-defaults uses before re-storing.
  public func withContent(html: String? = nil, props: [StudioTweakProp]? = nil) -> StudioArtifact {
    StudioArtifact(
      id: id,
      kind: kind,
      createdAt: createdAt,
      updatedAt: updatedAt,
      revision: revision,
      title: title,
      sourcePath: sourcePath,
      html: html ?? self.html,
      variants: variants,
      props: props ?? self.props,
      warnings: warnings,
      branchName: branchName,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId,
      sourceProjectPath: sourceProjectPath,
      sourceProcessId: sourceProcessId
    )
  }

  /// The artifact with a replaced variant set (edits baked in from the panel).
  public func withVariants(_ newVariants: [StudioVariant]) -> StudioArtifact {
    StudioArtifact(
      id: id,
      kind: kind,
      createdAt: createdAt,
      updatedAt: updatedAt,
      revision: revision,
      title: title,
      sourcePath: sourcePath,
      html: html,
      variants: newVariants,
      props: props,
      warnings: warnings,
      branchName: branchName,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId,
      sourceProjectPath: sourceProjectPath,
      sourceProcessId: sourceProcessId
    )
  }

  // MARK: Codable

  private enum CodingKeys: String, CodingKey {
    case id, kind, createdAt, updatedAt, revision, title, sourcePath, html, variants, props, warnings
    case branchName, sourceProvider, sourceSessionId, sourceProjectPath, sourceProcessId
  }

  /// `props` is optional on the wire so payloads written before it existed
  /// still decode.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    kind = try c.decode(StudioArtifactKind.self, forKey: .kind)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    title = try c.decode(String.self, forKey: .title)
    sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
    html = try c.decodeIfPresent(String.self, forKey: .html)
    variants = try c.decodeIfPresent([StudioVariant].self, forKey: .variants) ?? []
    props = try c.decodeIfPresent([StudioTweakProp].self, forKey: .props) ?? []
    warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    branchName = try c.decodeIfPresent(String.self, forKey: .branchName)
    sourceProvider = try c.decode(WorktreeLaunchProvider.self, forKey: .sourceProvider)
    sourceSessionId = try c.decodeIfPresent(String.self, forKey: .sourceSessionId)
    sourceProjectPath = try c.decodeIfPresent(String.self, forKey: .sourceProjectPath)
    sourceProcessId = try c.decode(Int32.self, forKey: .sourceProcessId)
  }
}
