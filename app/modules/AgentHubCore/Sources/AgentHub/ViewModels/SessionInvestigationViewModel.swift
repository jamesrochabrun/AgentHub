//
//  SessionInvestigationViewModel.swift
//  AgentHub
//
//  UI state for the session investigation prototype.
//

import Foundation

@MainActor
@Observable
public final class SessionInvestigationViewModel {
  private let service: any SessionInvestigationServiceProtocol
  @ObservationIgnored private var investigationTask: Task<Void, Never>?

  public private(set) var isRunning = false
  public private(set) var statusMessage = "Ready"
  public private(set) var report: SessionInvestigationReport?
  public private(set) var errorMessage: String?

  public init(service: any SessionInvestigationServiceProtocol) {
    self.service = service
  }

  deinit {
    investigationTask?.cancel()
  }

  public func start(snapshot: SessionInvestigationSnapshot) {
    investigationTask?.cancel()
    report = nil
    errorMessage = nil
    isRunning = true
    statusMessage = "Investigating sessions..."

    investigationTask = Task { [service] in
      do {
        let report = try await service.investigate(snapshot: snapshot)
        guard !Task.isCancelled else { return }
        self.report = report
        self.statusMessage = report.source == .claude ? "Investigation complete" : "Local fallback complete"
        self.isRunning = false
      } catch is CancellationError {
        self.statusMessage = "Investigation cancelled"
        self.isRunning = false
      } catch {
        self.errorMessage = error.localizedDescription
        self.statusMessage = "Investigation failed"
        self.isRunning = false
      }
    }
  }

  public func cancel() {
    investigationTask?.cancel()
    investigationTask = nil
    isRunning = false
    statusMessage = "Investigation cancelled"

    Task {
      await service.cancelActiveInvestigation()
    }
  }
}
