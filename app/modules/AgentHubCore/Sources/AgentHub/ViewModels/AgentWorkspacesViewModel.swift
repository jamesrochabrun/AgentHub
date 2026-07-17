//
//  AgentWorkspacesViewModel.swift
//  AgentHub
//
//  Main-actor orchestration for provider-neutral terminal workspaces.
//

import AgentHubSessionGraph
import Foundation

@MainActor
@Observable
public final class AgentWorkspacesViewModel {
  private struct DetectionKey: Hashable {
    let workspaceID: String
    let provider: SessionProviderKind
    let contextID: String
  }

  private struct PendingDetection: Sendable {
    let workspaceID: String
    let provider: SessionProviderKind
    let surfaceContextID: String?
    let projectPath: String
    let startedAt: Date
    let baseline: AccessorySessionDetectionBaseline
    let origin: SessionRelationshipOrigin
  }

  private struct SessionIdentity: Hashable {
    let provider: SessionProviderKind
    let sessionID: String
  }

  private let store: (any AgentWorkspaceStoreProtocol)?
  private let metadataStore: SessionMetadataStore?
  private let terminalSurfaceFactory: any EmbeddedTerminalSurfaceFactory
  private let sessionCoordinator: any AgentWorkspaceSessionCoordinating
  private let detectionService: any AccessorySessionDetectionServiceProtocol
  private let processProviderResolver: any WorkspaceSessionProcessProviderResolving
  private let detectionPollInterval: Duration

  @ObservationIgnored private var activeSurfaces: [String: any EmbeddedTerminalSurface] = [:]
  @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var detectionTasks: [DetectionKey: Task<Void, Never>] = [:]
  @ObservationIgnored private var activeDetectionKeysByWorkspace: [String: Set<DetectionKey>] = [:]
  @ObservationIgnored private var didLoad = false

  public private(set) var workspaces: [AgentWorkspaceRecord] = []
  public private(set) var linksByWorkspaceID: [String: [AgentWorkspaceSessionLink]] = [:]
  public private(set) var errorMessage: String?

  public init(
    store: (any AgentWorkspaceStoreProtocol)?,
    metadataStore: SessionMetadataStore?,
    terminalSurfaceFactory: any EmbeddedTerminalSurfaceFactory,
    sessionCoordinator: any AgentWorkspaceSessionCoordinating,
    detectionService: any AccessorySessionDetectionServiceProtocol = AccessorySessionDetectionService(),
    processProviderResolver: any WorkspaceSessionProcessProviderResolving = WorkspaceSessionProcessProviderResolver(),
    detectionPollInterval: Duration = .seconds(1)
  ) {
    self.store = store
    self.metadataStore = metadataStore
    self.terminalSurfaceFactory = terminalSurfaceFactory
    self.sessionCoordinator = sessionCoordinator
    self.detectionService = detectionService
    self.processProviderResolver = processProviderResolver
    self.detectionPollInterval = detectionPollInterval
  }

  deinit {
    for task in saveTasks.values {
      task.cancel()
    }
    for task in detectionTasks.values {
      task.cancel()
    }
  }

  public func load() async {
    guard !didLoad else { return }
    didLoad = true
    guard let store else { return }

    do {
      async let loadedWorkspaces = store.loadAgentWorkspaces()
      async let loadedLinks = store.loadAgentWorkspaceSessionLinks()
      workspaces = try await loadedWorkspaces
      linksByWorkspaceID = Dictionary(grouping: try await loadedLinks, by: \.workspaceId)
      for workspace in workspaces where linksByWorkspaceID[workspace.id] == nil {
        linksByWorkspaceID[workspace.id] = []
      }
      await sessionCoordinator.restorePersistedSessions(persistedSessionReferences())
    } catch {
      errorMessage = "Could not restore workspaces: \(error.localizedDescription)"
    }
  }

  @discardableResult
  public func createWorkspace(projectPath: String) async -> String? {
    let path = Self.normalizedPath(projectPath)
    let snapshot = Self.initialSnapshot(projectPath: path)

    do {
      let workspace = try AgentWorkspaceRecord(projectPath: path, snapshot: snapshot)
      if let store {
        try await store.saveAgentWorkspace(workspace, links: [])
      }
      workspaces.insert(workspace, at: 0)
      linksByWorkspaceID[workspace.id] = []
      errorMessage = nil
      return workspace.id
    } catch {
      errorMessage = "Could not create workspace: \(error.localizedDescription)"
      return nil
    }
  }

  public func renameWorkspace(id: String, name: String?) async {
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    workspaces[index].customName = trimmed?.isEmpty == false ? trimmed : nil
    workspaces[index].updatedAt = .now
    await persistWorkspace(id: id)
  }

  public func closeWorkspace(id: String) async {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    cancelDetection(for: id)
    activeSurfaces.removeValue(forKey: id)?.terminateProcess()

    do {
      try await store?.deleteAgentWorkspace(id: id)
      workspaces.removeAll { $0.id == id }
      linksByWorkspaceID.removeValue(forKey: id)
      errorMessage = nil
    } catch {
      errorMessage = "Could not close workspace: \(error.localizedDescription)"
    }
  }

  public func terminateAllTerminals() {
    for surface in activeSurfaces.values {
      surface.terminateProcess()
    }
    activeSurfaces.removeAll()
  }

  public func workspaces(for projectPath: String) -> [AgentWorkspaceRecord] {
    let path = Self.normalizedPath(projectPath)
    return workspaces
      .filter { Self.normalizedPath($0.projectPath) == path }
      .sorted { $0.createdAt < $1.createdAt }
  }

  public func workspace(id: String) -> AgentWorkspaceRecord? {
    workspaces.first { $0.id == id }
  }

  public func displayName(for workspace: AgentWorkspaceRecord) -> String {
    if let customName = workspace.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !customName.isEmpty {
      return customName
    }
    let projectWorkspaces = workspaces(for: workspace.projectPath)
    guard let index = projectWorkspaces.firstIndex(where: { $0.id == workspace.id }), index > 0 else {
      return "Workspace"
    }
    return "Workspace \(index + 1)"
  }

  public func linkedAgentCount(for workspaceID: String) -> Int {
    linksByWorkspaceID[workspaceID]?.count ?? 0
  }

  public func workspaceID(
    owningSession sessionId: String,
    provider: SessionProviderKind
  ) -> String? {
    linksByWorkspaceID.first { _, links in
      links.contains { $0.providerKind == provider && $0.sessionId == sessionId }
    }?.key
  }

  /// Routes a sidebar selection of a workspace-owned session to the pane that
  /// hosts it. Returns the owning workspace ID so the caller can select the
  /// workspace, or nil when no workspace owns the session.
  @discardableResult
  public func focusWorkspaceSession(
    provider: SessionProviderKind,
    sessionId: String,
    isDark: Bool
  ) -> String? {
    guard let workspaceID = workspaceID(owningSession: sessionId, provider: provider) else {
      return nil
    }
    terminalSurface(for: workspaceID, isDark: isDark)?
      .focusWorkspaceSession(provider: provider, sessionId: sessionId)
    return workspaceID
  }

  public func paneCount(for workspace: AgentWorkspaceRecord) -> Int {
    (try? workspace.decodedSnapshot().panels.count) ?? 0
  }

  public func activity(for workspaceID: String) -> AgentWorkspaceActivity {
    sessionCoordinator.activity(for: linksByWorkspaceID[workspaceID] ?? [])
  }

  public func requiresCloseConfirmation(id: String) -> Bool {
    activeSurfaces[id] != nil || !(linksByWorkspaceID[id]?.isEmpty ?? true)
  }

  public func terminalSurface(
    for workspaceID: String,
    isDark: Bool
  ) -> (any EmbeddedTerminalSurface)? {
    if let existing = activeSurfaces[workspaceID] {
      return existing
    }
    guard let workspace = workspace(id: workspaceID),
          let snapshot = try? workspace.decodedSnapshot() else {
      return nil
    }

    let surface = terminalSurfaceFactory.makeSurface(for: .ghostty)
    surface.updateContext(
      terminalSessionKey: "workspace-\(workspace.id)",
      sessionViewModel: nil
    )
    surface.onWorkspaceChanged = { [weak self] snapshot in
      self?.handleWorkspaceChanged(snapshot, workspaceID: workspaceID)
    }
    surface.workspaceCLIConfigurationProvider = { [weak self] provider in
      self?.sessionCoordinator.cliConfiguration(for: provider)
        ?? (provider == .claude ? .claudeDefault : .codexDefault)
    }
    let initialWorkingDirectory = snapshot.panels
      .first(where: { $0.role == .primary })?
      .tabs.first?
      .workingDirectory ?? workspace.projectPath
    surface.configureShell(projectPath: initialWorkingDirectory, isDark: isDark, shellPath: nil)
    surface.restoreWorkspaceSnapshot(snapshot)
    activeSurfaces[workspaceID] = surface
    syncPassiveDetectionContexts(snapshot, workspaceID: workspaceID)
    return surface
  }

  public func launchSurface(
    workspaceID: String,
    kind: WorkspaceTerminalLaunchKind,
    placement: WorkspaceSurfacePlacement,
    isDark: Bool
  ) {
    guard let workspace = workspace(id: workspaceID),
          let surface = terminalSurface(for: workspaceID, isDark: isDark) else {
      return
    }

    let provider: SessionProviderKind? = if case .agent(let provider) = kind {
      provider
    } else {
      nil
    }
    let startedAt = Date.now
    let baseline = provider.map {
      detectionService.makeBaseline(
        provider: $0,
        projectPath: surface.activeWorkingDirectory() ?? workspace.projectPath,
        startedAt: startedAt
      )
    }
    let configuration = provider.map(sessionCoordinator.cliConfiguration(for:))

    guard let context = surface.openWorkspaceSurface(
      kind: kind,
      placement: placement,
      cliConfiguration: configuration,
      projectPath: workspace.projectPath,
      metadataStore: metadataStore
    ) else {
      errorMessage = "The terminal is still starting. Try again in a moment."
      return
    }

    errorMessage = nil
    guard let provider, let baseline else { return }
    if let detectionContextID = context.detectionContextID {
      cancelDetection(
        workspaceID: workspaceID,
        surfaceContextID: detectionContextID
      )
    }
    startDetection(
      PendingDetection(
        workspaceID: workspaceID,
        provider: provider,
        surfaceContextID: context.detectionContextID,
        projectPath: context.projectPath,
        startedAt: context.startedAt,
        baseline: baseline,
        origin: .explicit
      ),
      contextID: context.detectionContextID.map { "explicit-\($0)" }
        ?? "explicit-\(UUID().uuidString)"
    )
  }

  public func clearError() {
    errorMessage = nil
  }

  private func handleWorkspaceChanged(
    _ snapshot: TerminalWorkspaceSnapshot,
    workspaceID: String
  ) {
    guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
    do {
      try workspaces[index].updateSnapshot(snapshot)
      reconcileLinks(from: snapshot, workspaceID: workspaceID)
      syncPassiveDetectionContexts(snapshot, workspaceID: workspaceID)
      scheduleSave(workspaceID: workspaceID)
    } catch {
      errorMessage = "Could not save workspace layout: \(error.localizedDescription)"
    }
  }

  private func reconcileLinks(
    from snapshot: TerminalWorkspaceSnapshot,
    workspaceID: String
  ) {
    let linkedSessions = snapshot.panels.flatMap(\.tabs).compactMap(\.linkedSession)
    let identities = Set(linkedSessions.map {
      SessionIdentity(provider: $0.provider, sessionID: $0.sessionId)
    })
    let existing = linksByWorkspaceID[workspaceID] ?? []
    let existingByIdentity: [SessionIdentity: AgentWorkspaceSessionLink] = Dictionary(
      uniqueKeysWithValues: existing.compactMap { link -> (SessionIdentity, AgentWorkspaceSessionLink)? in
      guard let provider = link.providerKind else { return nil }
      return (SessionIdentity(provider: provider, sessionID: link.sessionId), link)
      }
    )

    linksByWorkspaceID[workspaceID] = identities.map { identity in
      existingByIdentity[identity] ?? AgentWorkspaceSessionLink(
        workspaceId: workspaceID,
        provider: identity.provider,
        sessionId: identity.sessionID,
        origin: .detected
      )
    }
  }

  private func syncPassiveDetectionContexts(
    _: TerminalWorkspaceSnapshot,
    workspaceID: String
  ) {
    guard let surface = activeSurfaces[workspaceID] else { return }
    let contexts = surface.workspaceSessionDetectionContexts()
    var currentKeys: Set<DetectionKey> = []

    for context in contexts {
      let path = Self.normalizedPath(context.projectPath)
      for provider in SessionProviderKind.allCases {
        let contextID = "passive-\(context.id)"
        let key = DetectionKey(
          workspaceID: workspaceID,
          provider: provider,
          contextID: contextID
        )
        currentKeys.insert(key)
        guard detectionTasks[key] == nil else { continue }
        let startedAt = Date.now
        startDetection(
          PendingDetection(
            workspaceID: workspaceID,
            provider: provider,
            surfaceContextID: context.id,
            projectPath: path,
            startedAt: startedAt,
            baseline: detectionService.makeBaseline(
              provider: provider,
              projectPath: path,
              startedAt: startedAt
            ),
            origin: .detected
          ),
          contextID: contextID
        )
      }
    }

    let previousKeys = activeDetectionKeysByWorkspace[workspaceID] ?? []
    for key in previousKeys.subtracting(currentKeys) {
      detectionTasks[key]?.cancel()
      detectionTasks[key] = nil
    }
    activeDetectionKeysByWorkspace[workspaceID] = currentKeys
  }

  private func startDetection(
    _ pending: PendingDetection,
    contextID: String
  ) {
    let key = DetectionKey(
      workspaceID: pending.workspaceID,
      provider: pending.provider,
      contextID: contextID
    )
    let pollInterval = detectionPollInterval
    let processProviderResolver = processProviderResolver
    let executableNames = executableNamesByProvider()
    detectionTasks[key]?.cancel()
    detectionTasks[key] = Task { [weak self, pending, key] in
      while !Task.isCancelled {
        try? await Task.sleep(for: pollInterval)
        guard !Task.isCancelled, let self else { return }
        if let surfaceContextID = pending.surfaceContextID {
          guard let context = self.activeSurfaces[pending.workspaceID]?
            .workspaceSessionDetectionContexts()
            .first(where: { $0.id == surfaceContextID }) else {
            self.detectionTasks[key] = nil
            return
          }
          let provider: SessionProviderKind? = if let provider = context.provider {
            provider
          } else if let processID = context.foregroundProcessID {
            await processProviderResolver.provider(
              for: processID,
              executableNames: executableNames
            )
          } else {
            nil
          }
          guard provider == pending.provider else { continue }
        }
        guard let result = self.detectionService.detectNewSession(
          provider: pending.provider,
          projectPath: pending.projectPath,
          startedAt: pending.startedAt,
          baseline: pending.baseline
        ) else {
          continue
        }
        self.detectionTasks[key] = nil
        await self.resolveDetection(pending, result: result)
        return
      }
    }
  }

  private func resolveDetection(
    _ pending: PendingDetection,
    result: AccessorySessionDetectionResult
  ) async {
    let isAlreadyLinked = (linksByWorkspaceID[pending.workspaceID] ?? []).contains {
      $0.providerKind == result.provider && $0.sessionId == result.sessionId
    }
    guard !isAlreadyLinked else {
      rebaselineDetection(pending)
      return
    }
    guard let surface = activeSurfaces[pending.workspaceID] else { return }
    let didMarkSession = if let surfaceContextID = pending.surfaceContextID {
      surface.markWorkspaceSession(
        contextID: surfaceContextID,
        provider: result.provider,
        sessionId: result.sessionId,
        projectPath: result.projectPath,
        origin: pending.origin
      )
    } else {
      surface.markAccessorySession(
        provider: result.provider,
        sessionId: result.sessionId,
        projectPath: result.projectPath,
        origin: pending.origin
      )
    }
    guard didMarkSession else {
      return
    }

    var links = linksByWorkspaceID[pending.workspaceID] ?? []
    links.removeAll {
      $0.providerKind == result.provider && $0.sessionId == result.sessionId
    }
    links.append(
      AgentWorkspaceSessionLink(
        workspaceId: pending.workspaceID,
        provider: result.provider,
        sessionId: result.sessionId,
        origin: pending.origin
      )
    )
    linksByWorkspaceID[pending.workspaceID] = links

    if let snapshot = surface.captureWorkspaceSnapshot() {
      handleWorkspaceChanged(snapshot, workspaceID: pending.workspaceID)
    }
    await persistWorkspaceImmediately(id: pending.workspaceID)
    refreshPassiveDetectionBaselines(
      workspaceID: pending.workspaceID,
      provider: pending.provider,
      excludingSurfaceContextID: pending.surfaceContextID
    )
    await sessionCoordinator.monitorDetectedSession(result)
  }

  private func scheduleSave(workspaceID: String) {
    saveTasks[workspaceID]?.cancel()
    saveTasks[workspaceID] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let self else { return }
      await persistWorkspace(id: workspaceID)
      saveTasks[workspaceID] = nil
    }
  }

  private func persistWorkspace(id: String) async {
    guard let workspace = workspace(id: id), let store else { return }
    do {
      try await store.saveAgentWorkspace(
        workspace,
        links: linksByWorkspaceID[id] ?? []
      )
      errorMessage = nil
    } catch {
      errorMessage = "Could not save workspace: \(error.localizedDescription)"
    }
  }

  private func persistWorkspaceImmediately(id: String) async {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    await persistWorkspace(id: id)
  }

  private func persistedSessionReferences() -> [AgentWorkspaceSessionReference] {
    var referencesByIdentity: [SessionIdentity: AgentWorkspaceSessionReference] = [:]

    for workspace in workspaces {
      var projectPathByIdentity: [SessionIdentity: String] = [:]
      if let snapshot = try? workspace.decodedSnapshot() {
        for tab in snapshot.panels.flatMap(\.tabs) {
          guard let linkedSession = tab.linkedSession else { continue }
          let identity = SessionIdentity(
            provider: linkedSession.provider,
            sessionID: linkedSession.sessionId
          )
          let projectPath = tab.workingDirectory
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : Self.normalizedPath($0) }
            ?? Self.normalizedPath(workspace.projectPath)
          projectPathByIdentity[identity] = projectPath
          referencesByIdentity[identity] = AgentWorkspaceSessionReference(
            provider: identity.provider,
            sessionId: identity.sessionID,
            projectPath: projectPath
          )
        }
      }

      for link in linksByWorkspaceID[workspace.id] ?? [] {
        guard let provider = link.providerKind else { continue }
        let identity = SessionIdentity(provider: provider, sessionID: link.sessionId)
        referencesByIdentity[identity] = AgentWorkspaceSessionReference(
          provider: provider,
          sessionId: link.sessionId,
          projectPath: projectPathByIdentity[identity]
            ?? Self.normalizedPath(workspace.projectPath)
        )
      }
    }

    return referencesByIdentity.values.sorted {
      if $0.provider != $1.provider {
        return $0.provider.rawValue < $1.provider.rawValue
      }
      return $0.sessionId < $1.sessionId
    }
  }

  private func cancelDetection(for workspaceID: String) {
    let keys = detectionTasks.keys.filter { $0.workspaceID == workspaceID }
    for key in keys {
      detectionTasks[key]?.cancel()
      detectionTasks[key] = nil
    }
    activeDetectionKeysByWorkspace[workspaceID] = nil
  }

  private func cancelDetection(
    workspaceID: String,
    surfaceContextID: String
  ) {
    let keys = detectionTasks.keys.filter {
      $0.workspaceID == workspaceID
        && ($0.contextID == "passive-\(surfaceContextID)"
          || $0.contextID == "explicit-\(surfaceContextID)")
    }
    for key in keys {
      detectionTasks[key]?.cancel()
      detectionTasks[key] = nil
      activeDetectionKeysByWorkspace[workspaceID]?.remove(key)
    }
  }

  private func refreshPassiveDetectionBaselines(
    workspaceID: String,
    provider: SessionProviderKind,
    excludingSurfaceContextID: String?
  ) {
    let excludedKey = excludingSurfaceContextID.map { "passive-\($0)" }
    let keys = detectionTasks.keys.filter {
      $0.workspaceID == workspaceID
        && $0.provider == provider
        && $0.contextID.hasPrefix("passive-")
        && $0.contextID != excludedKey
    }
    for key in keys {
      detectionTasks[key]?.cancel()
      detectionTasks[key] = nil
      activeDetectionKeysByWorkspace[workspaceID]?.remove(key)
    }
    guard let surface = activeSurfaces[workspaceID],
          let snapshot = surface.captureWorkspaceSnapshot() else { return }
    syncPassiveDetectionContexts(snapshot, workspaceID: workspaceID)
  }

  private func rebaselineDetection(_ pending: PendingDetection) {
    guard let surfaceContextID = pending.surfaceContextID,
          let context = activeSurfaces[pending.workspaceID]?
            .workspaceSessionDetectionContexts()
            .first(where: { $0.id == surfaceContextID }) else {
      return
    }
    let startedAt = Date.now
    let projectPath = Self.normalizedPath(context.projectPath)
    let contextID = "\(pending.origin == .explicit ? "explicit" : "passive")-\(surfaceContextID)"
    let key = DetectionKey(
      workspaceID: pending.workspaceID,
      provider: pending.provider,
      contextID: contextID
    )
    if pending.origin == .detected {
      activeDetectionKeysByWorkspace[pending.workspaceID, default: []].insert(key)
    }
    startDetection(
      PendingDetection(
        workspaceID: pending.workspaceID,
        provider: pending.provider,
        surfaceContextID: surfaceContextID,
        projectPath: projectPath,
        startedAt: startedAt,
        baseline: detectionService.makeBaseline(
          provider: pending.provider,
          projectPath: projectPath,
          startedAt: startedAt
        ),
        origin: pending.origin
      ),
      contextID: contextID
    )
  }

  private func executableNamesByProvider() -> [SessionProviderKind: String] {
    Dictionary(
      uniqueKeysWithValues: SessionProviderKind.allCases.map { provider in
        (provider, sessionCoordinator.cliConfiguration(for: provider).executableName)
      }
    )
  }

  private static func initialSnapshot(projectPath: String) -> TerminalWorkspaceSnapshot {
    TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .shell,
              name: "Shell",
              title: "Shell",
              workingDirectory: projectPath
            )
          ]
        )
      ]
    )
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
      .path
  }
}
