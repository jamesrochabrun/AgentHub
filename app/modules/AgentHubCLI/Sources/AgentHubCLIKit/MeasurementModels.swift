import Foundation

/// A single measurement an agent filed from a session — the unit the Measurements panel
/// renders.
///
/// Deliberately a *data spec*, never markup: the agent supplies the claim and the
/// numbers, AgentHub draws the chart. That keeps every card on the app's theme,
/// keeps agent-authored HTML out of the panel, and leaves the card structured
/// enough to re-run later.
public struct MeasurementRecord: Codable, Equatable, Identifiable, Sendable {
  /// Caps on how much a single card may carry.
  ///
  /// These are guardrails, not preferences: the record is persisted to the
  /// session database, so an agent that dumps a 100k-row export would bloat the
  /// store and stall the panel. Exceeding a cap is a tool-level validation
  /// error, which the agent can see and correct by aggregating first — which is
  /// what a chart wants anyway.
  public enum Limits {
    public static let maxSeries = 12
    public static let maxPointsPerSeries = 200
    public static let maxTableRows = 200
    public static let maxTableColumns = 12
    public static let maxCaveats = 10
    /// How many previous runs a card keeps. A measurement re-run weekly holds
    /// several months of history; past that the oldest run is dropped rather
    /// than letting one card grow without bound.
    public static let maxHistoryRuns = 20
  }

  public let id: String
  /// When this measurement was first filed. Preserved across re-runs so a refreshed
  /// card keeps its place in the panel instead of jumping to the top.
  public let createdAt: Date
  /// When the numbers were last refreshed. `nil` for a measurement that has never
  /// been re-run — decoding older payloads relies on that, so keep it optional.
  public let updatedAt: Date?
  /// Short headline for the card ("Weekly actives by signup cohort").
  public let title: String
  /// The measurement in plain English — what a PM would paste into a review.
  public let claim: String
  /// The question this analysis set out to answer, when the agent states one.
  public let question: String?
  /// The SQL/code that produced the numbers. Collapsed in the UI, but present:
  /// a claim whose query cannot be inspected is an assertion, not a measurement.
  public let query: String?
  /// Where the data came from (table, file, endpoint) — free text for now, and
  /// the seam a future metrics/semantic layer plugs into.
  public let source: String?
  /// Known limitations: partial windows, excluded segments, small samples.
  public let caveats: [String]
  public let chart: MeasurementChart?
  public let table: MeasurementTable?

  /// Earlier runs of this same measurement, oldest first — the point of re-running
  /// is watching a number move, which requires not throwing the old one away.
  /// `nil` on a measurement that has never been re-run, which is also what lets
  /// payloads written before history existed still decode.
  public let history: [MeasurementRun]?

  /// The branch the current values were measured on, stamped by the app from
  /// the recording session. Measurements roll up to the repo, so without this a
  /// `main` run and a feature-branch run would be indistinguishable in history.
  public let branchName: String?
  /// The worktree the current values were measured in, when not the repo root.
  public let worktreePath: String?

  public let sourceProvider: WorktreeLaunchProvider
  public let sourceSessionId: String?
  public let sourceProjectPath: String?
  public let sourceProcessId: Int32

  /// The timestamp to show on the card: when the numbers were last refreshed.
  public var displayDate: Date {
    updatedAt ?? createdAt
  }

  public var hasBeenRerun: Bool {
    updatedAt != nil
  }

  /// Re-anchors an incoming re-run onto the card it replaces.
  ///
  /// The original filing date is kept (so the refreshed card holds its place),
  /// the incoming timestamp becomes the update time, and the values being
  /// replaced are pushed onto the history rather than discarded.
  public func replacing(_ previous: MeasurementRecord) -> MeasurementRecord {
    let carried = (previous.history ?? []) + [MeasurementRun(supersededBy: previous)]

    return MeasurementRecord(
      id: previous.id,
      createdAt: previous.createdAt,
      updatedAt: createdAt,
      title: title,
      claim: claim,
      question: question,
      query: query,
      source: source,
      caveats: caveats,
      chart: chart,
      table: table,
      history: Array(carried.suffix(Limits.maxHistoryRuns)),
      branchName: branchName,
      worktreePath: worktreePath,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId,
      sourceProjectPath: sourceProjectPath,
      sourceProcessId: sourceProcessId
    )
  }

  /// Records which branch and worktree produced the current values.
  ///
  /// Stamped by the app rather than the CLI: the app already knows the session's
  /// branch, and asking the helper to shell out to `git` would be both slower
  /// and wrong inside a detached or mid-rebase checkout.
  public func stamped(branchName: String?, worktreePath: String?) -> MeasurementRecord {
    MeasurementRecord(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
      title: title,
      claim: claim,
      question: question,
      query: query,
      source: source,
      caveats: caveats,
      chart: chart,
      table: table,
      history: history,
      branchName: branchName,
      worktreePath: worktreePath,
      sourceProvider: sourceProvider,
      sourceSessionId: sourceSessionId,
      sourceProjectPath: sourceProjectPath,
      sourceProcessId: sourceProcessId
    )
  }

  /// Every run of this measurement, oldest first, with the current values last.
  public var runs: [MeasurementRun] {
    (history ?? []) + [MeasurementRun(supersededBy: self)]
  }

  /// The single number this measurement measures, when it measures exactly one —
  /// a scalar like "build time" or "row count". `nil` for anything with more
  /// than one series or one point, where "the value" is not a single number.
  public var scalarValue: Double? {
    guard let chart,
          chart.series.count == 1,
          let series = chart.series.first,
          series.points.count == 1
    else {
      return nil
    }
    return series.points[0].y
  }

  public init(
    id: String = UUID().uuidString,
    createdAt: Date = .now,
    updatedAt: Date? = nil,
    title: String,
    claim: String,
    question: String? = nil,
    query: String? = nil,
    source: String? = nil,
    caveats: [String] = [],
    chart: MeasurementChart? = nil,
    table: MeasurementTable? = nil,
    history: [MeasurementRun]? = nil,
    branchName: String? = nil,
    worktreePath: String? = nil,
    sourceProvider: WorktreeLaunchProvider,
    sourceSessionId: String?,
    sourceProjectPath: String? = nil,
    sourceProcessId: Int32
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.title = title
    self.claim = claim
    self.question = question
    self.query = query
    self.source = source
    self.caveats = caveats
    self.chart = chart
    self.table = table
    self.history = history
    self.branchName = branchName
    self.worktreePath = worktreePath
    self.sourceProvider = sourceProvider
    self.sourceSessionId = sourceSessionId
    self.sourceProjectPath = sourceProjectPath
    self.sourceProcessId = sourceProcessId
  }
}

/// One execution of a measurement's query — the values as they stood at that moment.
///
/// Kept so a card can answer "what was this last month, and what did we say
/// about it then", which a card that only holds its latest values cannot.
public struct MeasurementRun: Codable, Equatable, Sendable, Identifiable {
  public var id: Date { runAt }

  public let runAt: Date
  public let claim: String
  public let chart: MeasurementChart?
  public let table: MeasurementTable?
  /// The branch this run measured. Without it, runs from different branches
  /// interleave into one series and a stable metric reads as thrashing.
  /// `nil` for runs recorded before branches were tracked.
  public let branchName: String?

  public init(
    runAt: Date,
    claim: String,
    chart: MeasurementChart?,
    table: MeasurementTable?,
    branchName: String? = nil
  ) {
    self.runAt = runAt
    self.claim = claim
    self.chart = chart
    self.table = table
    self.branchName = branchName
  }

  /// Snapshots the values a record held before being refreshed.
  public init(supersededBy record: MeasurementRecord) {
    self.init(
      runAt: record.displayDate,
      claim: record.claim,
      chart: record.chart,
      table: record.table,
      branchName: record.branchName
    )
  }

  /// See `MeasurementRecord.scalarValue`.
  public var scalarValue: Double? {
    guard let chart,
          chart.series.count == 1,
          let series = chart.series.first,
          series.points.count == 1
    else {
      return nil
    }
    return series.points[0].y
  }
}

/// A chart specification: what to draw, not how it looks.
public struct MeasurementChart: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case bar
    case line
    case area
    case point
  }

  public let kind: Kind
  public let xLabel: String?
  public let yLabel: String?
  public let series: [MeasurementSeries]
  /// Explicit left-to-right order for the category axis.
  ///
  /// Needed whenever series cover different categories: Swift Charts otherwise
  /// derives the axis from the order categories first appear, which for a
  /// branch-split trend groups all of one branch's dates before the other's and
  /// renders them out of chronological order. `nil` keeps the derived order.
  public let xOrder: [String]?

  public init(
    kind: Kind,
    xLabel: String? = nil,
    yLabel: String? = nil,
    series: [MeasurementSeries],
    xOrder: [String]? = nil
  ) {
    self.kind = kind
    self.xLabel = xLabel
    self.yLabel = yLabel
    self.series = series
    self.xOrder = xOrder
  }

  /// Total plotted points, used for limit checks.
  public var pointCount: Int {
    series.reduce(0) { $0 + $1.points.count }
  }
}

public struct MeasurementSeries: Codable, Equatable, Sendable, Identifiable {
  public var id: String { name }
  public let name: String
  public let points: [MeasurementPoint]

  public init(name: String, points: [MeasurementPoint]) {
    self.name = name
    self.points = points
  }
}

/// One plotted value.
///
/// `x` stays a string on purpose: cohort names, dates and buckets all arrive as
/// labels from a `GROUP BY`, and a single category axis renders every one of
/// them without asking the agent to declare an axis type it would often get
/// wrong.
public struct MeasurementPoint: Codable, Equatable, Sendable {
  public let x: String
  public let y: Double

  public init(x: String, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct MeasurementTable: Codable, Equatable, Sendable {
  public let columns: [String]
  public let rows: [[String]]

  public init(columns: [String], rows: [[String]]) {
    self.columns = columns
    self.rows = rows
  }
}
