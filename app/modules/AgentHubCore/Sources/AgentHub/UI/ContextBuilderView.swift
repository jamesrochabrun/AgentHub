//
//  ContextBuilderView.swift
//  AgentHub
//
//  Curate exact launch context: pick project files, watch the approximate
//  token cost, preview the exact assembled block, and apply or save it as a
//  reusable context set. In launch mode a leading rail lists the saved sets —
//  tap to load one, edit it, and save; "Use This Context" stays the primary
//  action in the header.
//

import AppKit
import SwiftUI

public enum ContextBuilderMode {
  /// Launcher curation: primary button applies the selection to the pending
  /// launch. The profile is non-nil when the selection is an unmodified saved
  /// set, so the caller can keep the set's identity instead of going ad-hoc.
  case launch(onApply: (ContextSelection, ContextProfile?) -> Void)
  /// Context-set editing: primary button saves back into the set being edited.
  case editProfile(onSave: (ContextProfile) -> Void)
  /// New context set: primary button names and saves the selection.
  case createProfile(onSave: (ContextProfile) -> Void)
}

public struct ContextBuilderView: View {
  @State private var viewModel: ContextBuilderViewModel
  @State private var showingSaveAsPopover = false
  @State private var showingDeleteConfirmation = false
  @State private var saveErrorMessage: String?
  @Environment(\.runtimeTheme) private var runtimeTheme
  private let mode: ContextBuilderMode
  private let onDeleted: (() -> Void)?
  private let onDismiss: () -> Void

  /// `onDeleted` opts the editor into showing its explicit delete action —
  /// only the Project Details flow passes it; the session launcher never
  /// exposes deletion.
  public init(
    viewModel: ContextBuilderViewModel,
    mode: ContextBuilderMode,
    onDeleted: (() -> Void)? = nil,
    onDismiss: @escaping () -> Void
  ) {
    _viewModel = State(initialValue: viewModel)
    self.mode = mode
    self.onDeleted = onDeleted
    self.onDismiss = onDismiss
  }

  private var isLaunchMode: Bool {
    if case .launch = mode { return true }
    return false
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(alignment: .top, spacing: 0) {
        if isLaunchMode && viewModel.profileServiceAvailable {
          ContextSetsSidePanel(viewModel: viewModel)
            .frame(width: 190)
          Divider()
        }
        ContextFilePickerPane(viewModel: viewModel)
          .frame(minWidth: 250, idealWidth: 280)
        Divider()
        selectionColumn
          .frame(minWidth: 380)
      }
    }
    .frame(
      minWidth: isLaunchMode ? 880 : 700,
      idealWidth: isLaunchMode ? 980 : 780,
      minHeight: 540,
      idealHeight: 640
    )
    .task {
      await viewModel.prepareSearchIndex()
      await viewModel.loadProfiles()
      await viewModel.refreshMetrics()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      Text(headerTitle)
        .font(.primaryDefault)
        .fontWeight(.semibold)

      Spacer()

      Button("Cancel", action: onDismiss)
        .keyboardShortcut(.cancelAction)

      if case .launch(let onApply) = mode {
        Button("Use This Context") {
          onApply(viewModel.currentSelection(), viewModel.unmodifiedSourceProfile)
          onDismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .tint(Color.brandPrimary(from: runtimeTheme))
        .disabled(!viewModel.hasSelection)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var headerTitle: String {
    switch mode {
    case .launch: return "Session Context"
    case .editProfile: return viewModel.sourceProfile.map { "Edit “\($0.name)”" } ?? "Edit Context Set"
    case .createProfile: return "New Context Set"
    }
  }

  // MARK: - Selection Column

  private var selectionColumn: some View {
    VStack(alignment: .leading, spacing: 10) {
      ContextSelectedFilesList(viewModel: viewModel)
      ContextTokenBudgetBar(viewModel: viewModel)
      instructionsEditor
      ContextAssembledPreview(viewModel: viewModel)
      bottomBar
    }
    .padding(14)
  }

  private var instructionsEditor: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Instructions (included in the context block)")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
      TextEditor(text: Bindable(viewModel).instructions)
        .font(.system(size: 12))
        .scrollContentBackground(.hidden)
        .padding(4)
        .frame(minHeight: 44, maxHeight: 80)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
  }

  // MARK: - Bottom bar (save actions)

  private var bottomBar: some View {
    HStack(spacing: 10) {
      if showsDeleteButton {
        deleteButton
      }
      if let saveErrorMessage {
        Text(saveErrorMessage)
          .font(.secondaryCaption)
          .foregroundColor(.red)
          .lineLimit(1)
      }
      Spacer()
      saveAction
    }
  }

  private var showsDeleteButton: Bool {
    guard case .editProfile = mode else { return false }
    return onDeleted != nil && viewModel.sourceProfile != nil
  }

  private var deleteButton: some View {
    Button {
      showingDeleteConfirmation = true
    } label: {
      Label("Delete Context Set", systemImage: "trash")
        .foregroundColor(.primary)
    }
    .buttonStyle(.bordered)
    .alert(
      "Delete “\(viewModel.sourceProfile?.name ?? "")”?",
      isPresented: $showingDeleteConfirmation
    ) {
      Button("Delete", role: .destructive) {
        Task {
          guard let profile = viewModel.sourceProfile else { return }
          await viewModel.deleteProfile(profile)
          onDeleted?()
          onDismiss()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The context set is removed everywhere it is offered at session launch. Files on disk are not touched.")
    }
  }

  @ViewBuilder
  private var saveAction: some View {
    switch mode {
    case .launch:
      if viewModel.profileServiceAvailable {
        if viewModel.sourceProfile != nil {
          saveChangesButton(isPrimary: false, onSaved: { _ in })
        } else {
          saveAsNewButton(isPrimary: false)
        }
      }
    case .editProfile(let onSave):
      saveChangesButton(isPrimary: true) { saved in
        onSave(saved)
        onDismiss()
      }
    case .createProfile:
      saveAsNewButton(isPrimary: true)
    }
  }

  private func saveChangesButton(
    isPrimary: Bool,
    onSaved: @escaping (ContextProfile) -> Void
  ) -> some View {
    let button = Button("Save Changes") {
      Task {
        do {
          if let saved = try await viewModel.saveEditedProfile() {
            saveErrorMessage = nil
            onSaved(saved)
          }
        } catch {
          saveErrorMessage = "Could not save context set."
        }
      }
    }
    .disabled(!viewModel.hasSelection || !viewModel.hasUnsavedChanges)

    // A tinted `.bordered` button renders a muddy translucent pill when
    // disabled — the primary style must be `.borderedProminent`, which grays
    // out properly.
    return Group {
      if isPrimary {
        button
          .buttonStyle(.borderedProminent)
          .tint(Color.brandPrimary(from: runtimeTheme))
      } else {
        button
          .buttonStyle(.bordered)
      }
    }
  }

  private func saveAsNewButton(isPrimary: Bool) -> some View {
    let button = Button("Save as Context Set…") {
      showingSaveAsPopover = true
    }
    .disabled(!viewModel.hasSelection)

    return Group {
      if isPrimary {
        button
          .buttonStyle(.borderedProminent)
          .tint(Color.brandPrimary(from: runtimeTheme))
      } else {
        button
          .buttonStyle(.bordered)
      }
    }
    .popover(isPresented: $showingSaveAsPopover, arrowEdge: .top) {
      ContextProfileSaveForm { name, scope in
        Task {
          do {
            if let saved = try await viewModel.saveAsProfile(name: name, scope: scope) {
              saveErrorMessage = nil
              showingSaveAsPopover = false
              if case .createProfile(let onSave) = mode {
                onSave(saved)
                onDismiss()
              }
            }
          } catch {
            saveErrorMessage = "Could not save context set."
          }
        }
      }
    }
  }
}

// MARK: - Context sets rail

/// Leading rail in launch mode: saved context sets, tap to load and edit.
private struct ContextSetsSidePanel: View {
  let viewModel: ContextBuilderViewModel
  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var hoveredProfileID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("CONTEXT SETS")
        .font(.geist(size: 10, weight: .semibold))
        .foregroundColor(.secondary)
        .kerning(0.6)

      Button {
        viewModel.startNewDraft()
      } label: {
        Label("New Context Set", systemImage: "plus")
          .font(.secondaryCaption)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)

      Divider()

      if viewModel.availableProfiles.isEmpty {
        Text("Saved sets appear here.")
          .font(.secondaryCaption)
          .foregroundColor(.secondary.opacity(0.7))
          .padding(.top, 4)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(viewModel.availableProfiles) { profile in
              setRow(profile)
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
  }

  private func setRow(_ profile: ContextProfile) -> some View {
    let isSelected = viewModel.sourceProfile?.id == profile.id
    let isHovered = hoveredProfileID == profile.id
    return HStack(spacing: 6) {
      Image(systemName: profile.isDefault ? "star.fill" : "square.stack.3d.up")
        .font(.system(size: 10))
        .foregroundColor(isSelected ? Color.brandPrimary(from: runtimeTheme) : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(profile.name)
          .font(.system(size: 12))
          .foregroundColor(.primary)
          .lineLimit(1)
        if profile.scope == .personal {
          Text("Global")
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(
          isSelected
            ? Color.brandPrimary(from: runtimeTheme).opacity(0.14)
            : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
    )
    .contentShape(Rectangle())
    .onTapGesture {
      Task { await viewModel.applyProfile(profile) }
    }
    .onHover { hovering in
      hoveredProfileID = hovering ? profile.id : (hoveredProfileID == profile.id ? nil : hoveredProfileID)
    }
  }
}

// MARK: - Save Form

private struct ContextProfileSaveForm: View {
  @State private var name: String = ""
  @State private var scope: ContextProfileScope = .project
  @Environment(\.runtimeTheme) private var runtimeTheme
  let onSave: (String, ContextProfileScope) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Save as Context Set")
        .font(.primaryDefault)
        .fontWeight(.semibold)
      TextField("Context set name", text: $name)
        .textFieldStyle(.roundedBorder)
      Picker("Scope", selection: $scope) {
        Text("This project").tag(ContextProfileScope.project)
        Text("Global (all projects)").tag(ContextProfileScope.personal)
      }
      .pickerStyle(.radioGroup)
      HStack {
        Spacer()
        Button("Save") {
          onSave(name, scope)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .tint(Color.brandPrimary(from: runtimeTheme))
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(14)
    .frame(width: 260)
  }
}
