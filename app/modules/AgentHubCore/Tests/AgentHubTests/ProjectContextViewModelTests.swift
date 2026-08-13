import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Project context view model")
struct ProjectContextViewModelTests {

  private func withProject(
    _ body: (URL, ProjectContextViewModel, MockContextProfileService) async throws -> Void
  ) async throws {
    let project = FileManager.default.temporaryDirectory
      .appendingPathComponent("project-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }

    let service = MockContextProfileService()
    let viewModel = ProjectContextViewModel(
      projectPath: project.path,
      service: service,
      fileLoader: ContextFileLoader(fileIndexService: FileIndexService())
    )
    try await body(project, viewModel, service)
  }

  @Test("Load lists profiles and estimates tokens for resolvable files")
  func loadListsAndEstimates() async throws {
    try await withProject { project, viewModel, service in
      let content = String(repeating: "a", count: 400)
      try content.write(
        to: project.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
      service.storedProfiles = [
        ContextProfile(
          id: "p1",
          name: "One",
          scope: .project,
          projectPath: project.path,
          selection: ContextSelection(files: [ContextFileSelection(relativePath: "a.swift")])
        )
      ]

      await viewModel.load()

      #expect(viewModel.profiles.map(\.id) == ["p1"])
      // 400 bytes / 4 × 1.15 = 115.
      #expect(viewModel.estimatedTokensByProfileId["p1"] == 115)
    }
  }

  @Test("Delete removes through the service and reloads")
  func deleteRemovesAndReloads() async throws {
    try await withProject { project, viewModel, service in
      service.storedProfiles = [
        ContextProfile(id: "p1", name: "One", scope: .project, projectPath: project.path, selection: ContextSelection()),
        ContextProfile(id: "p2", name: "Two", scope: .project, projectPath: project.path, selection: ContextSelection()),
      ]
      await viewModel.load()

      await viewModel.delete(viewModel.profiles[0])

      #expect(service.deletedIds == ["p1"])
      #expect(viewModel.profiles.map(\.id) == ["p2"])
    }
  }

  @Test("Set default flows through the service, and nil clears it")
  func setDefaultFlows() async throws {
    try await withProject { project, viewModel, service in
      service.storedProfiles = [
        ContextProfile(id: "p1", name: "One", scope: .project, projectPath: project.path, selection: ContextSelection())
      ]
      await viewModel.load()

      await viewModel.setDefault(viewModel.profiles[0])
      #expect(service.defaultRequests == ["p1"])
      #expect(viewModel.profiles.first?.isDefault == true)

      await viewModel.setDefault(nil)
      #expect(service.defaultRequests == ["p1", nil])
      #expect(viewModel.profiles.first?.isDefault == false)
    }
  }

  @Test("Without a service the tab reports unavailable and stays inert")
  func unavailableWithoutService() async {
    let viewModel = ProjectContextViewModel(projectPath: "/tmp/project", service: nil)
    #expect(!viewModel.isAvailable)
    await viewModel.load()
    #expect(viewModel.profiles.isEmpty)
  }
}
