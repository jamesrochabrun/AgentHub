import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Context builder view model")
struct ContextBuilderViewModelTests {

  private func withProject(
    _ body: (URL, ContextBuilderViewModel, MockContextProfileService) async throws -> Void
  ) async throws {
    let project = FileManager.default.temporaryDirectory
      .appendingPathComponent("context-builder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }

    let service = MockContextProfileService()
    let viewModel = ContextBuilderViewModel(
      projectPath: project.path,
      fileLoader: ContextFileLoader(fileIndexService: FileIndexService()),
      profileService: service,
      fileIndexService: FileIndexService()
    )
    try await body(project, viewModel, service)
  }

  private func write(_ relativePath: String, _ content: String, in project: URL) throws {
    let url = project.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  @Test("Toggling a file updates per-file and total token estimates")
  func toggleUpdatesTokens() async throws {
    try await withProject { project, viewModel, _ in
      try write("a.swift", String(repeating: "a", count: 400), in: project)

      await viewModel.toggleSelection(relativePath: "a.swift")

      #expect(viewModel.selectedRows.count == 1)
      // 400 bytes / 4 × 1.15 = 115.
      #expect(viewModel.selectedRows.first?.estimatedTokens == 115)
      #expect(viewModel.totalEstimatedTokens == 115)

      await viewModel.toggleSelection(relativePath: "a.swift")
      #expect(viewModel.selectedRows.isEmpty)
      #expect(viewModel.totalEstimatedTokens == 0)
    }
  }

  @Test("Instructions contribute to the total estimate")
  func instructionsContribute() async throws {
    try await withProject { _, viewModel, _ in
      viewModel.instructions = String(repeating: "b", count: 40)
      // 40 bytes / 4 × 1.15 = 11.5 → 12.
      #expect(viewModel.totalEstimatedTokens == 12)
    }
  }

  @Test("Window fraction uses the configured model's resolved context window")
  func windowFractionUsesResolvedModel() {
    let oneMillion = ContextBuilderViewModel(
      projectPath: "/tmp/project", modelIdentifier: "claude-sonnet-4-5[1m]")
    #expect(oneMillion.contextWindowTokens == 1_000_000)

    let standard = ContextBuilderViewModel(
      projectPath: "/tmp/project", modelIdentifier: "claude-opus-4-8")
    #expect(standard.contextWindowTokens == 200_000)

    standard.instructions = String(repeating: "a", count: 4_000)
    oneMillion.instructions = String(repeating: "a", count: 4_000)
    #expect(standard.windowFraction > oneMillion.windowFraction)
  }

  @Test("Applying a profile loads its valid subset and flags missing paths")
  func applyProfileFlagsMissing() async throws {
    try await withProject { project, viewModel, _ in
      try write("real.swift", "let real = 1", in: project)
      let profile = ContextProfile(
        name: "Mixed",
        scope: .project,
        projectPath: project.path,
        selection: ContextSelection(
          files: [
            ContextFileSelection(relativePath: "real.swift"),
            ContextFileSelection(relativePath: "gone.swift"),
          ],
          instructions: "From profile."
        )
      )

      await viewModel.applyProfile(profile)

      #expect(viewModel.instructions == "From profile.")
      #expect(viewModel.selectedRows.count == 2)
      #expect(viewModel.missingPaths == ["gone.swift"])
      #expect(viewModel.selectedRows.first { $0.relativePath == "real.swift" }?.isMissing == false)
    }
  }

  @Test("Save-as-profile persists the current selection through the service")
  func saveAsProfilePersists() async throws {
    try await withProject { project, viewModel, service in
      try write("a.swift", "let a = 1", in: project)
      await viewModel.toggleSelection(relativePath: "a.swift")
      viewModel.instructions = "Save me."

      let saved = try #require(try await viewModel.saveAsProfile(name: " Voice work ", scope: .project))

      #expect(saved.name == "Voice work")
      #expect(service.savedProfiles.count == 1)
      #expect(service.savedProfiles.first?.selection.files.map(\.relativePath) == ["a.swift"])
      #expect(service.savedProfiles.first?.selection.instructions == "Save me.")
      #expect(viewModel.sourceProfile?.id == saved.id)
    }
  }

  @Test("Save Changes is gated on actual edits to the loaded set")
  func unsavedChangesGating() async throws {
    try await withProject { project, viewModel, _ in
      try write("a.swift", "let a = 1", in: project)
      let profile = ContextProfile(
        id: "gate",
        name: "Gate",
        scope: .project,
        projectPath: project.path,
        selection: ContextSelection(
          files: [ContextFileSelection(relativePath: "a.swift")],
          instructions: "original"
        )
      )
      await viewModel.applyProfile(profile)
      #expect(!viewModel.hasUnsavedChanges)

      viewModel.instructions = "edited"
      #expect(viewModel.hasUnsavedChanges)

      _ = try await viewModel.saveEditedProfile()
      #expect(!viewModel.hasUnsavedChanges)

      await viewModel.toggleSelection(relativePath: "a.swift")  // remove the file
      #expect(viewModel.hasUnsavedChanges)

      // A fresh draft has no source set, so nothing to "save changes" to.
      viewModel.startNewDraft()
      #expect(!viewModel.hasUnsavedChanges)
    }
  }

  @Test("Text snippets add, count toward tokens, round-trip, and gate saves")
  func textSnippetsFlow() async throws {
    try await withProject { _, viewModel, _ in
      viewModel.addTextSnippet(title: "  Notes  ", content: String(repeating: "n", count: 400))

      #expect(viewModel.textSnippets.count == 1)
      #expect(viewModel.textSnippets.first?.title == "Notes")
      // 400 bytes / 4 x 1.15 = 115.
      #expect(viewModel.totalEstimatedTokens == 115)
      #expect(viewModel.hasSelection)

      let selection = viewModel.currentSelection()
      #expect(selection.textSnippets.count == 1)

      // Blank title or empty content are rejected.
      viewModel.addTextSnippet(title: "   ", content: "x")
      viewModel.addTextSnippet(title: "y", content: "")
      #expect(viewModel.textSnippets.count == 1)

      await viewModel.refreshPreview()
      #expect(viewModel.assembledPreview.contains("<snippet title=\"Notes\">"))

      viewModel.removeTextSnippet(id: viewModel.textSnippets[0].id)
      #expect(viewModel.textSnippets.isEmpty)
      #expect(!viewModel.hasSelection)
    }
  }

  @Test("Deleting the loaded set removes it and resets to a fresh draft")
  func deleteLoadedSetResets() async throws {
    try await withProject { project, viewModel, service in
      try write("a.swift", "let a = 1", in: project)
      let profile = makeProfile(id: "doomed", name: "Doomed", projectPath: project.path)
      service.storedProfiles = [profile]
      await viewModel.loadProfiles()
      await viewModel.applyProfile(profile)

      await viewModel.deleteProfile(profile)

      #expect(service.deletedIds == ["doomed"])
      #expect(viewModel.availableProfiles.isEmpty)
      #expect(viewModel.sourceProfile == nil)
      #expect(viewModel.selectedRows.isEmpty)
    }
  }

  @Test("Starting a new draft clears the loaded set and selection")
  func startNewDraftClears() async throws {
    try await withProject { project, viewModel, _ in
      try write("a.swift", "let a = 1", in: project)
      await viewModel.applyProfile(makeProfile(id: "loaded", name: "Loaded", projectPath: project.path))
      #expect(viewModel.sourceProfile != nil)
      #expect(!viewModel.selectedRows.isEmpty)

      viewModel.startNewDraft()

      #expect(viewModel.sourceProfile == nil)
      #expect(viewModel.selectedRows.isEmpty)
      #expect(viewModel.instructions.isEmpty)
      #expect(viewModel.assembledPreview.isEmpty)
    }
  }

  @Test("Saving an edited profile keeps its identity and updates the selection")
  func saveEditedProfileKeepsIdentity() async throws {
    try await withProject { project, viewModel, service in
      try write("new.swift", "let new = 1", in: project)
      let original = ContextProfile(
        id: "stable-id",
        name: "Editable",
        scope: .project,
        projectPath: project.path,
        selection: ContextSelection(files: [ContextFileSelection(relativePath: "old.swift")])
      )
      await viewModel.applyProfile(original)
      viewModel.removeSelection(relativePath: "old.swift")
      await viewModel.toggleSelection(relativePath: "new.swift")

      let saved = try #require(try await viewModel.saveEditedProfile())

      #expect(saved.id == "stable-id")
      #expect(saved.selection.files.map(\.relativePath) == ["new.swift"])
      #expect(service.savedProfiles.first?.id == "stable-id")
    }
  }

  @Test("The preview is the exact assembled block")
  func previewMatchesAssembler() async throws {
    try await withProject { project, viewModel, _ in
      try write("a.swift", "let a = 1", in: project)
      await viewModel.toggleSelection(relativePath: "a.swift")
      viewModel.instructions = "Check."

      await viewModel.refreshPreview()

      let expected = ContextAssembler().assemble(ContextAssemblyInput(
        files: [ContextLoadedFile(relativePath: "a.swift", content: "let a = 1")],
        instructions: "Check."
      ))
      #expect(viewModel.assembledPreview == expected.block)
    }
  }

  @Test("External files can be added, classified, and round-tripped")
  func externalFilesFlow() async throws {
    try await withProject { project, viewModel, _ in
      let outside = project.deletingLastPathComponent()
        .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: outside) }
      let notes = outside.appendingPathComponent("notes.md")
      try String(repeating: "n", count: 400).write(to: notes, atomically: true, encoding: .utf8)
      let pdf = outside.appendingPathComponent("book.pdf")
      try Data([0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE]).write(to: pdf)

      await viewModel.addExternalFiles([notes, pdf, outside])

      let externalRows = viewModel.selectedRows.filter(\.isExternal)
      #expect(externalRows.count == 2)
      #expect(externalRows.first { $0.relativePath == notes.path }?.estimatedTokens == 115)
      #expect(externalRows.first { $0.relativePath == pdf.path }?.isAttachment == true)

      let selection = viewModel.currentSelection()
      #expect(Set(selection.externalPaths) == [notes.path, pdf.path])
      #expect(selection.files.isEmpty)

      await viewModel.refreshPreview()
      #expect(viewModel.assembledPreview.contains("<attachments>"))
      #expect(viewModel.assembledPreview.contains(String(repeating: "n", count: 50)))
      #expect(viewModel.previewTruncatedByteCount == nil)
    }
  }

  @Test("The preview display truncates huge blocks instead of freezing layout")
  func previewDisplayTruncates() async throws {
    try await withProject { project, viewModel, _ in
      try write("huge.txt", String(repeating: "x", count: 60_000), in: project)
      await viewModel.toggleSelection(relativePath: "huge.txt")

      await viewModel.refreshPreview()

      #expect(viewModel.assembledPreview.count == ContextBuilderViewModel.previewDisplayCharacterLimit)
      let fullBytes = try #require(viewModel.previewTruncatedByteCount)
      #expect(fullBytes > 60_000)
    }
  }

  @Test("Clearing the selection clears the truncation banner too")
  func emptySelectionClearsTruncationBanner() async throws {
    try await withProject { project, viewModel, _ in
      try write("huge.txt", String(repeating: "x", count: 60_000), in: project)
      await viewModel.toggleSelection(relativePath: "huge.txt")
      await viewModel.refreshPreview()
      #expect(viewModel.previewTruncatedByteCount != nil)

      viewModel.removeSelection(relativePath: "huge.txt")
      await viewModel.refreshPreview()

      #expect(viewModel.assembledPreview.isEmpty)
      #expect(viewModel.previewTruncatedByteCount == nil)
    }
  }

  @Test("Binary project files show as attachments in the selection rows")
  func binaryProjectRowIsAttachment() async throws {
    try await withProject { project, viewModel, _ in
      let pdf = project.appendingPathComponent("spec.pdf")
      try Data([0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE]).write(to: pdf)

      await viewModel.toggleSelection(relativePath: "spec.pdf")

      let row = try #require(viewModel.selectedRows.first)
      #expect(row.isAttachment)
      #expect(!row.isMissing)
    }
  }

  @Test("An untouched saved set keeps its identity for launch apply; edits drop it")
  func unmodifiedSourceProfileGating() async throws {
    try await withProject { project, viewModel, _ in
      try write("a.swift", "let a = 1", in: project)
      let profile = ContextProfile(
        id: "set",
        name: "Set",
        scope: .project,
        projectPath: project.path,
        selection: ContextSelection(
          files: [ContextFileSelection(relativePath: "a.swift")],
          instructions: "keep"
        )
      )
      await viewModel.applyProfile(profile)
      #expect(viewModel.unmodifiedSourceProfile?.id == "set")

      viewModel.instructions = "changed"
      #expect(viewModel.unmodifiedSourceProfile == nil)

      viewModel.instructions = "keep"
      #expect(viewModel.unmodifiedSourceProfile?.id == "set")

      viewModel.startNewDraft()
      #expect(viewModel.unmodifiedSourceProfile == nil)
    }
  }

  @Test("File fallback hint appears when selected bytes exceed the threshold")
  func fallbackHint() async throws {
    let project = FileManager.default.temporaryDirectory
      .appendingPathComponent("context-builder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    try write("big.txt", String(repeating: "x", count: 600), in: project)

    let viewModel = ContextBuilderViewModel(
      projectPath: project.path,
      fileLoader: ContextFileLoader(fileIndexService: FileIndexService()),
      payloadThreshold: 512
    )
    await viewModel.toggleSelection(relativePath: "big.txt")

    #expect(viewModel.willUseFileFallback)
  }
}
