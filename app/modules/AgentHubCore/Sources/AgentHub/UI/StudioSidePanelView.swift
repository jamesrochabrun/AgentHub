//
//  StudioSidePanelView.swift
//  AgentHub
//
//  Embedded side panel that renders the artifacts and design canvases an agent
//  filed with agenthub_artifact / agenthub_design, served from AgentHub's own
//  localhost server, with the Canvas inspector for point-and-comment feedback.
//

import AgentHubCLIKit
import AppKit
import Canvas
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What a click in inspect mode does. Mirrors web preview's strip: Comment
/// (element-anchored instruction), Crop (region + screenshot), Edit (live
/// visual edits batched into one re-file request). Context mode is omitted
/// there too — Studio has no terminal-attachment queue to add context to.
private enum StudioInspectBehavior: String, CaseIterable, Identifiable {
  case comment, crop, edit

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .comment: return "square.and.pencil"
    case .crop: return "crop"
    case .edit: return "character.cursor.ibeam"
    }
  }

  var help: String {
    switch self {
    case .comment: return "Comment: click an element, describe the change, ⏎ sends it to the agent."
    case .crop: return "Crop: drag a region, describe the change, ⏎ sends it with a screenshot."
    case .edit: return "Edit: click an element and adjust it with the toolbar; Send hands the edits to the agent."
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .comment: return "Comment mode"
    case .crop: return "Crop region mode"
    case .edit: return "Visual edit mode"
    }
  }

  var canvasMode: InspectMode {
    switch self {
    case .comment, .edit: return .input
    case .crop: return .crop
    }
  }
}

struct StudioSidePanelView: View {
  let session: CLISession
  let viewModel: CLISessionsViewModel
  let onDismiss: () -> Void
  var isEmbedded = false
  let isExpanded: Bool
  var onToggleExpanded: (() -> Void)?
  let onSendPrompt: (String, CLISession) -> Void

  @State private var panelState = StudioPanelState()
  @State private var inspectState = ElementInspectState()
  @State private var inspectBehavior: StudioInspectBehavior = .comment
  @State private var editState = StudioDesignEditState()
  @State private var servedURL: URL?
  @State private var reloadUUID = UUID()
  @State private var isLoading = false
  @State private var webView: WKWebView?
  @State private var isConfirmingDelete = false
  @State private var transientNotice: String?

  // Canvas edits bake straight into the payload (Studio is a scratchpad):
  // debounced auto-save, quiet reload suppression for the revision we wrote,
  // and a baseline to revert to.
  @State private var bakeTask: Task<Void, Never>?
  @State private var quietRevisionExpectation: Int?
  @State private var editBaseline: StudioArtifact?
  @State private var bakeState: BakeState = .idle
  @State private var pageMessageHandler = StudioPageMessageHandler()

  private enum BakeState: Equatable { case idle, saving, saved, failed(String) }

  // Tweaks — the page declares a schema (canvas host page from `props`, or a
  // document calling dc_set_props); the panel edits values live in the page.
  @State private var tweaksState = TweaksState()
  @State private var tweaksAgentState: TweaksAgentState = .idle
  @State private var tweaksDefaultsSaveState: TweaksDefaultsSaveState = .idle
  @State private var tweakGenerationTimer = TweakGenerationTimer()
  @State private var isTweaksPopoverPresented = false
  @State private var hasDeclaredTweakProps = false
  @State private var tweaksAgentRevisionBaseline: Int?
  @Environment(\.openURL) private var openURL

  private var artifacts: [StudioArtifact] {
    viewModel.studioArtifacts(for: session)
  }

  private var selectedArtifact: StudioArtifact? {
    panelState.selectedArtifact(in: artifacts)
  }

  private var reloadToken: String {
    panelState.reloadToken(for: selectedArtifact)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let selectedArtifact {
        content(for: selectedArtifact)
      } else {
        emptyState
      }
    }
    .frame(
      minWidth: 300, idealWidth: .infinity, maxWidth: .infinity,
      minHeight: 300, idealHeight: .infinity, maxHeight: .infinity
    )
    .onChange(of: artifacts) { previous, current in
      panelState.reconcileSelection(previous: previous, current: current)
    }
    .task(id: reloadToken) {
      await resolveServedURL()
    }
    .onChange(of: reloadToken) {
      // A revision we produced by baking edits: the DOM already equals the
      // stored markup, so keep the page, the selection, and the toolbar.
      if let expected = quietRevisionExpectation, selectedArtifact?.revision == expected {
        quietRevisionExpectation = nil
        return
      }
      quietRevisionExpectation = nil
      inspectState.dismissInput()
      inspectState.dismissCropRect()
      editState.clear()
      editBaseline = nil
      bakeState = .idle
      reloadUUID = UUID()
      // A re-file after an agent tweak request means the agent came back.
      if let selectedArtifact, let baseline = tweaksAgentRevisionBaseline,
         selectedArtifact.revision > baseline {
        tweaksAgentRevisionBaseline = nil
        tweaksAgentState = .idle
        tweakGenerationTimer.stop()
      }
      tweaksDefaultsSaveState = .idle
    }
    .onChange(of: selectedArtifact?.id) { previous, _ in
      if let previous { flushPendingBake(artifactId: previous) }
      editState.clear()
      editBaseline = nil
      bakeState = .idle
      tweaksState.clear()
      hasDeclaredTweakProps = false
      tweaksAgentState = .idle
      tweaksAgentRevisionBaseline = nil
      isTweaksPopoverPresented = false
    }
    .onKeyPress(.escape) {
      if inspectState.isActive {
        deactivateInspect()
        return .handled
      }
      guard !isEmbedded else { return .handled }
      onDismiss()
      return .handled
    }
    .onDisappear {
      if let selectedArtifact { flushPendingBake(artifactId: selectedArtifact.id) }
    }
    .alert("Delete this artifact?", isPresented: $isConfirmingDelete) {
      Button("Delete", role: .destructive, action: deleteSelected)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It is removed from every session in this project. The agent can file it again.")
    }
  }

  // MARK: - Content

  @ViewBuilder
  private func content(for artifact: StudioArtifact) -> some View {
    if let failureMessage = panelState.failureMessage {
      failureState(message: failureMessage)
    } else if let servedURL {
      VStack(spacing: 0) {
        if !artifact.warnings.isEmpty {
          StudioWarningsBanner(warnings: artifact.warnings)
          Divider()
        }
        webContent(url: servedURL, artifact: artifact)
      }
    } else {
      ProgressView("Starting Studio server…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func webContent(url: URL, artifact: StudioArtifact) -> some View {
    InspectableWebView(
      url: url,
      isFileURL: false,
      inspectorDataLevel: inspectBehavior == .edit ? .full : .regular,
      onLoadingChange: { isLoading = $0 },
      onError: { message in panelState.failureMessage = message },
      reloadToken: reloadUUID,
      onElementSelected: { element in handleElementSelected(element, artifact: artifact) },
      onSelectedElementDataChange: { element in
        inspectState.refreshSelectedElement(element)
        editState.refresh(with: element)
      },
      onSelectedElementViewportRectChange: { rect in inspectState.updateSelectedElementViewportRect(rect) },
      onCropRectSelected: { rect, elements in inspectState.selectCropRect(rect, elements: elements) },
      onCropRectViewportChange: { rect in inspectState.updateCropRect(rect) },
      isInspectModeActive: $inspectState.isActive,
      inspectMode: inspectBehavior.canvasMode,
      selectedElementId: inspectState.selectedElement?.id,
      onWebViewReady: { readyWebView in
        // The page's per-artboard Implement buttons post here. Registered
        // synchronously (not a @State write) so it exists before the page
        // script checks for it.
        pageMessageHandler.onImplement = { variantName in
          Task { @MainActor in
            if let selectedArtifact { await promote(artifact: selectedArtifact, variantName: variantName) }
          }
        }
        let controller = readyWebView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: StudioPageMessageHandler.name)
        controller.add(WeakScriptMessageHandler(pageMessageHandler), name: StudioPageMessageHandler.name)
        // Deferred: this fires from makeNSView, and a @State write during a
        // view update is dropped — which leaves every setProp/snapshot call
        // with no web view to talk to.
        Task { @MainActor in webView = readyWebView }
      },
      onTweakPropsChange: handleTweakPropsChange,
      onTweakSchemaAvailabilityChange: { hasDeclaredTweakProps = $0 }
    )
    .overlay {
      if inspectBehavior != .edit {
        Color.clear
          .allowsHitTesting(false)
          .webInspectorOverlay(
            state: inspectState,
            inputPlacement: .selectionAnchored,
            onSubmit: { element, instruction in
              sendFeedback(artifact: artifact, element: element, instruction: instruction)
            },
            onSubmitAndSend: { element, instruction in
              sendFeedback(artifact: artifact, element: element, instruction: instruction)
            },
            onCropSubmit: { rect, elements, instruction in
              sendCrop(artifact: artifact, rect: rect, elements: elements, instruction: instruction)
            },
            onCropSubmitAndSend: { rect, elements, instruction in
              sendCrop(artifact: artifact, rect: rect, elements: elements, instruction: instruction)
            },
            deactivateOnSubmit: false
          )
      }
    }
    .overlay(alignment: .top) {
      if isLoading {
        ProgressView()
          .progressViewStyle(.linear)
          .frame(height: 2)
          .accessibilityLabel("Loading artifact")
      } else if inspectState.isActive, inspectBehavior == .edit {
        editToolbar(for: artifact)
      }
    }
    .overlay(alignment: .bottom) {
      VStack(spacing: 8) {
        if inspectState.isActive, inspectBehavior == .edit, editState.hasPendingEdits {
          pendingEditsBar(for: artifact)
        }
        if let transientNotice {
          Text(transientNotice)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity)
        }
      }
      .padding(.bottom, 12)
    }
    .overlay(alignment: .topLeading) {
      if inspectState.isActive, inspectBehavior != .edit {
        Text(inspectHint(for: artifact))
          .font(.caption)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
          .padding(10)
          .allowsHitTesting(false)
      }
    }
  }

  private func inspectHint(for artifact: StudioArtifact) -> String {
    switch inspectBehavior {
    case .comment:
      return artifact.kind == .canvas
        ? "Click any element on a variant, describe the change, and press ⏎ to send it to the agent."
        : "Click any element, describe the change, and press ⏎ to send it to the agent."
    case .crop:
      return "Drag a region, describe the change, and press ⏎ to send it with a screenshot."
    case .edit:
      return ""
    }
  }

  /// Edit mode: the design toolbar for the selected element, floating at the top.
  @ViewBuilder
  private func editToolbar(for artifact: StudioArtifact) -> some View {
    if let element = editState.selectedElement, let values = editState.toolbarValues {
      VStack(alignment: .leading, spacing: 6) {
        WebPreviewTextContentEditor(
          elementKey: element.cssSelector,
          sourceText: values.textContent,
          onTextChange: { text in
            applyEdit(DesignEdit(element: element, action: .updateTextContent(text)), artifact: artifact)
          }
        )
        DesignToolbarContent(
          values: values,
          element: element,
          isTextContentEditable: false,
          onEdit: { edit in applyEdit(edit, artifact: artifact) }
        )
      }
      .padding(8)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .padding(10)
      .transition(.move(edge: .top).combined(with: .opacity))
    } else {
      Text(artifact.kind == .canvas
           ? "Click any element to edit it. Changes save into the canvas as you go — Implement uses them."
           : "Click any element to edit it. Send hands every change to the agent as one request.")
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private func pendingEditsBar(for artifact: StudioArtifact) -> some View {
    if artifact.kind == .canvas {
      HStack(spacing: 10) {
        switch bakeState {
        case .saving:
          ProgressView().controlSize(.mini)
          Text("Saving edits into the canvas…").font(.caption)
        case .failed(let message):
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(message).font(.caption).lineLimit(1)
        case .idle, .saved:
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brandPrimary)
          Text(editState.pendingChangeCount == 1 ? "1 edit saved into the canvas" : "\(editState.pendingChangeCount) edits saved into the canvas")
            .font(.caption.weight(.medium))
        }
        if editBaseline != nil {
          Button("Revert", role: .destructive) { revertBakedEdits() }
            .controlSize(.small)
            .help("Restore the canvas as the agent last filed it")
        }
        Text("Implement ▾ sends the edited variant")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial, in: Capsule())
    } else {
      HStack(spacing: 10) {
        Image(systemName: "pencil.and.list.clipboard")
          .foregroundStyle(Color.brandPrimary)
        Text(editState.pendingChangeCount == 1 ? "1 pending edit" : "\(editState.pendingChangeCount) pending edits")
          .font(.caption.weight(.medium))
        Button("Discard", role: .destructive) { discardPendingEdits() }
          .controlSize(.small)
        Button("Send to Agent") { sendPendingEdits(for: artifact) }
          .controlSize(.small)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: [.command])
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial, in: Capsule())
    }
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No Studio Artifacts",
      systemImage: "paintpalette",
      description: Text("The agent has not rendered an artifact or design canvas for this project yet.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failureState(message: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      ContentUnavailableView(
        "Couldn't Load Artifact",
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )
      Button("Try Again") { panelState.reload() }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "paintpalette")
        .foregroundStyle(Color.brandPrimary)
        .accessibilityHidden(true)

      Text("Studio")
        .font(.headline)

      if artifacts.count == 1, let selectedArtifact {
        Text(selectedArtifact.title)
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 12)

      if artifacts.count > 1 {
        Picker("Artifact", selection: Binding(
          get: { selectedArtifact?.id },
          set: { panelState.selectedArtifactId = $0 }
        )) {
          ForEach(artifacts) { artifact in
            Label(pickerLabel(for: artifact), systemImage: artifact.kind == .canvas ? "square.grid.2x2" : "doc.richtext")
              .tag(Optional(artifact.id))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .accessibilityLabel("Select artifact")
      }

      if let selectedArtifact {
        inspectButton
        if inspectState.isActive {
          inspectModeStrip
        }
        if hasDeclaredTweakProps || tweaksState.hasProps || tweaksAgentState == .working {
          tweaksButton(for: selectedArtifact)
        }
        if selectedArtifact.kind == .canvas {
          promoteMenu(for: selectedArtifact)
        }
        moreMenu(for: selectedArtifact)
      }

      Button(action: { panelState.reload() }) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(selectedArtifact == nil)
      .accessibilityLabel("Reload artifact")
      .help("Reload")

      if let onToggleExpanded {
        Button(action: onToggleExpanded) {
          Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse Studio" : "Expand Studio to full width")
        .help(isExpanded ? "Collapse (⌘⇧O)" : "Expand to full width (⌘⇧O)")
      }

      closeButton
    }
    .overlay {
      if let onToggleExpanded {
        Button("") { onToggleExpanded() }
          .keyboardShortcut("o", modifiers: [.command, .shift])
          .hidden()
          .frame(width: 0, height: 0)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var inspectModeStrip: some View {
    HStack(spacing: 2) {
      ForEach(StudioInspectBehavior.allCases) { behavior in
        Button {
          switchInspectBehavior(to: behavior)
        } label: {
          Image(systemName: behavior.icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(inspectBehavior == behavior ? Color.white : Color.secondary)
            .frame(width: 22, height: 22)
            .background(
              RoundedRectangle(cornerRadius: 5)
                .fill(inspectBehavior == behavior ? Color.brandPrimary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(behavior.accessibilityLabel)
        .help(behavior.help)
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
  }

  private var inspectButton: some View {
    Button {
      if inspectState.isActive {
        deactivateInspect()
      } else {
        inspectState.activate(mode: inspectBehavior.canvasMode)
      }
    } label: {
      Image(systemName: "cursorarrow.click.2")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(inspectState.isActive ? Color.brandPrimary : Color.secondary)
        .frame(width: 24, height: 24)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(inspectState.isActive ? Color.brandPrimary.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(servedURL == nil)
    .accessibilityLabel(inspectState.isActive ? "Stop inspecting" : "Inspect")
    .help(inspectState.isActive ? "Stop inspecting (Esc)" : "Inspect: comment on, crop, or edit any element")
  }

  /// Live controls for the props the page declared. Value changes go straight
  /// into the page; Save defaults re-stores the artifact; Ideas/Custom/Delete
  /// go to the session agent as re-file prompts.
  private func tweaksButton(for artifact: StudioArtifact) -> some View {
    let presentation = TweaksButtonPresentation.resolve(agentState: tweaksAgentState)
    return Button {
      isTweaksPopoverPresented.toggle()
    } label: {
      ZStack {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(isTweaksPopoverPresented ? Color.brandPrimary : Color.secondary)
          .opacity(presentation.isLoading ? 0 : 1)
        if presentation.isLoading {
          ProgressView().controlSize(.mini)
        }
      }
      .frame(width: 24, height: 24)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isTweaksPopoverPresented ? Color.brandPrimary.opacity(0.15) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(presentation.accessibilityLabel)
    .help(artifact.kind == .canvas ? "Tweak the shared props across every variant" : "Tweak this design with live controls")
    .popover(isPresented: $isTweaksPopoverPresented, arrowEdge: .bottom) {
      WebPreviewTweaksPanel(
        state: tweaksState,
        agentState: $tweaksAgentState,
        defaultsSaveState: $tweaksDefaultsSaveState,
        generationStartedAt: tweakGenerationTimer.startedAt,
        onSubmitDescription: { instruction in
          sendTweaksAgentPrompt(StudioTweaksPromptBuilder.customPrompt(artifact: artifact, instruction: instruction))
        },
        onIdeas: {
          sendTweaksAgentPrompt(StudioTweaksPromptBuilder.ideasPrompt(artifact: artifact, existingProps: tweaksState.props))
        },
        onValueChange: handleTweakValueChange,
        onDeleteAll: {
          sendTweaksAgentPrompt(StudioTweaksPromptBuilder.deleteAllPrompt(artifact: artifact))
        },
        onReset: resetTweakValues,
        onSaveDefaults: { saveTweakDefaults(for: artifact) }
      )
    }
  }

  /// The one action in Studio that asks for real code. Its own control, its own
  /// prompt builder — never reachable from Send. Labelled, not icon-only: this
  /// is the step users are looking for once they have picked a direction.
  private func promoteMenu(for artifact: StudioArtifact) -> some View {
    Menu {
      Section("Ask the agent to build it") {
        ForEach(artifact.variants, id: \.name) { variant in
          Button {
            Task { @MainActor in await promote(artifact: artifact, variantName: variant.name) }
          } label: {
            Label("Implement \u{201C}\(variant.name)\u{201D}", systemImage: "hammer")
          }
        }
      }
      if let sourcePath = artifact.sourcePath {
        Text("Target: \(sourcePath)")
      }
      Text("Edits made in the panel are included.")
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "hammer.fill")
          .font(.system(size: 11, weight: .medium))
        Text("Implement")
          .font(.system(size: 12, weight: .medium))
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
      }
      .foregroundStyle(Color.brandPrimary)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.brandPrimary.opacity(0.12)))
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Implement a variant in the project")
    .help("Pick the variant to implement — the agent builds it in the real project, including your panel edits")
  }

  private func moreMenu(for artifact: StudioArtifact) -> some View {
    Menu {
      Button {
        if let servedURL { openURL(servedURL) }
      } label: {
        Label("Open in Browser", systemImage: "safari")
      }
      .disabled(servedURL == nil)

      Button {
        copyLink()
      } label: {
        Label("Copy Link", systemImage: "link")
      }
      .disabled(servedURL == nil)

      Button {
        exportDocument(artifact)
      } label: {
        Label("Export HTML…", systemImage: "square.and.arrow.up")
      }

      Divider()

      Button(role: .destructive) {
        isConfirmingDelete = true
      } label: {
        Label("Delete Artifact", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("More actions")
  }

  @ViewBuilder
  private var closeButton: some View {
    if isEmbedded {
      Button("Close", action: onDismiss)
    } else {
      Button("Close", action: onDismiss)
        .keyboardShortcut(.cancelAction)
    }
  }

  // MARK: - Actions

  private func resolveServedURL() async {
    guard let selectedArtifact, let library = viewModel.studioLibrary else {
      servedURL = nil
      return
    }
    let key = viewModel.projectScopeKey(for: session)
    let url = await library.servedURL(for: selectedArtifact, projectKey: key)
    guard !Task.isCancelled else { return }
    servedURL = url
    if url == nil {
      panelState.failureMessage = "AgentHub couldn't start its local Studio server."
    }
  }

  private func handleElementSelected(_ element: ElementInspectorData, artifact: StudioArtifact) {
    inspectState.selectElement(element)
    guard inspectBehavior == .edit else { return }
    // Selector parse gives an immediate (usually correct) variant; the page
    // is asked next for the authoritative answer.
    editState.select(element, variantName: StudioPanelState.variantName(fromSelector: element.cssSelector))
    guard artifact.kind == .canvas else { return }
    Task { @MainActor in
      let variantName = await resolveVariantName(for: element)
      // Re-select stamps the variant without disturbing an in-progress batch.
      if editState.selectedElement?.cssSelector == element.cssSelector {
        editState.select(element, variantName: variantName)
      }
    }
  }

  /// Edit-mode change: apply live, record, and (canvas) bake into the payload.
  private func applyEdit(_ edit: DesignEdit, artifact: StudioArtifact) {
    if artifact.kind == .canvas, editBaseline == nil {
      editBaseline = artifact
    }
    editState.apply(edit, in: webView)
    if case .deleteElement = edit.action, let webView {
      // The Canvas bridge ignores delete; Studio removes it in the page itself.
      let literal = Self.javaScriptStringLiteral(edit.element.cssSelector)
      webView.evaluateJavaScript("window.__agenthubStudio && window.__agenthubStudio.removeElement(\(literal))") { _, _ in }
    }
    guard artifact.kind == .canvas else { return }
    scheduleBake(artifactId: artifact.id)
  }

  private func scheduleBake(artifactId: String) {
    bakeTask?.cancel()
    bakeState = .saving
    bakeTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await bakeCanvasEdits(artifactId: artifactId)
    }
  }

  /// Runs any pending bake now (mode/artifact switch, panel close, Implement).
  private func flushPendingBake(artifactId: String) {
    guard bakeTask != nil || bakeState == .saving else { return }
    bakeTask?.cancel()
    bakeTask = nil
    Task { @MainActor in await bakeCanvasEdits(artifactId: artifactId) }
  }

  private func flushPendingBakeAndWait(artifactId: String) async {
    guard bakeTask != nil || bakeState == .saving else { return }
    bakeTask?.cancel()
    bakeTask = nil
    await bakeCanvasEdits(artifactId: artifactId)
  }

  /// Serializes every artboard the user touched and stores it as the
  /// variant's markup — quietly, so the page is not reloaded under the edit.
  private func bakeCanvasEdits(artifactId: String) async {
    bakeTask = nil
    guard let webView, let library = viewModel.studioLibrary,
          viewModel.studioArtifacts(for: session).contains(where: { $0.id == artifactId })
    else {
      bakeState = .idle
      return
    }
    let edits = editState.orderedEdits
    guard !edits.isEmpty else {
      bakeState = .idle
      return
    }
    // Variants known from selection first (a deleted element's selector no
    // longer resolves in the page); selectors only for the ones still unknown.
    let knownNames = edits.compactMap(\.variantName)
    let unresolvedSelectors = edits.filter { $0.variantName == nil }.map(\.batch.element.cssSelector)
    let namesJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: knownNames)) ?? Data("[]".utf8), as: UTF8.self)
    let selectorsJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: unresolvedSelectors)) ?? Data("[]".utf8), as: UTF8.self)
    let script = """
      (function () {
        var s = window.__agenthubStudio; if (!s) return null;
        var names = \(namesJSON);
        var byVariant = s.variantsForSelectors(\(selectorsJSON));
        Object.keys(byVariant).forEach(function (k) { if (names.indexOf(byVariant[k]) === -1) names.push(byVariant[k]); });
        return names.length ? s.serializeArtboards(names) : {};
      })()
      """
    let result = try? await webView.evaluateJavaScript(script)
    guard let htmlByVariant = result as? [String: String], !htmlByVariant.isEmpty else {
      bakeState = .failed("Couldn't read the edited artboards.")
      return
    }
    let key = viewModel.projectScopeKey(for: session)
    let before = library.artifact(id: artifactId, projectKey: key)?.revision ?? 0
    // Expect the revision this store produces so the reload handler keeps the page.
    quietRevisionExpectation = before + 1
    let stored = await library.updateVariantHTML(
      artifactId: artifactId,
      htmlByVariant: htmlByVariant,
      projectKey: key,
      sessionId: session.id,
      aliasPaths: []
    )
    if stored == nil || stored?.revision == before {
      quietRevisionExpectation = nil
    }
    bakeState = .saved
  }

  /// Restores the canvas as it was before the first panel edit (a normal
  /// store: the page reloads to the agent's version).
  private func revertBakedEdits() {
    guard let editBaseline, let library = viewModel.studioLibrary else { return }
    bakeTask?.cancel()
    bakeTask = nil
    let key = viewModel.projectScopeKey(for: session)
    let baseline = editBaseline
    self.editBaseline = nil
    editState.clear()
    bakeState = .idle
    Task { @MainActor in
      await library.store(baseline.withVariants(baseline.variants), projectKey: key, sessionId: session.id, aliasPaths: [])
      showNotice("Reverted to the agent's version")
    }
  }

  private func switchInspectBehavior(to behavior: StudioInspectBehavior) {
    guard behavior != inspectBehavior else { return }
    if let selectedArtifact { flushPendingBake(artifactId: selectedArtifact.id) }
    inspectState.dismissInput()
    inspectState.dismissCropRect()
    if let webView { ElementInspectorBridge.clearCropSelection(in: webView) }
    if inspectBehavior == .edit { editState.deselect() }
    inspectBehavior = behavior
    inspectState.mode = behavior.canvasMode
  }

  private func deactivateInspect() {
    inspectState.deactivate()
    inspectState.dismissCropRect()
    editState.deselect()
  }

  private func sendCrop(artifact: StudioArtifact, rect: CGRect, elements: [ElementInspectorData], instruction: String) {
    Task { @MainActor in
      var screenshotPath: String?
      if let webView, let image = try? await ElementSnapshotCapture.captureSnapshot(of: rect, in: webView) {
        screenshotPath = Self.saveCropScreenshot(image, sessionId: session.id)
      }
      let variantName: String? = artifact.kind == .canvas
        ? await elements.first.asyncFlatMap { await resolveVariantName(for: $0) }
        : nil
      let prompt = StudioFeedbackPromptBuilder.cropPrompt(
        artifact: artifact,
        variantName: variantName,
        cropRect: rect,
        elements: elements,
        instruction: instruction,
        screenshotPath: screenshotPath
      )
      inspectState.dismissCropRect()
      if let webView { ElementInspectorBridge.clearCropSelection(in: webView) }
      onSendPrompt(prompt, session)
      showNotice(screenshotPath == nil ? "Sent to the agent" : "Sent to the agent with a screenshot")
    }
  }

  private static func saveCropScreenshot(_ image: NSImage, sessionId: String) -> String? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHub/studio-crops", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("crop-\(sessionId.prefix(8))-\(Int(Date().timeIntervalSince1970)).png")
    do {
      try png.write(to: url)
      return url.path
    } catch {
      return nil
    }
  }

  private func sendPendingEdits(for artifact: StudioArtifact) {
    guard artifact.kind == .document else { return }
    let entries = editState.orderedEdits.map { entry -> StudioFeedbackPromptBuilder.ElementEdits in
      var lines: [String] = []
      for change in entry.batch.styleChanges {
        lines.append(change.oldValue.map { "- \(change.property): \($0) → \(change.newValue)" } ?? "- \(change.property): \(change.newValue)")
      }
      if let text = entry.batch.textChange {
        lines.append(text.oldText.map { "- text content: \"\($0)\" → \"\(text.newText)\"" } ?? "- text content: \"\(text.newText)\"")
      }
      if entry.fitToContent { lines.append("- size: fit to content (width and height auto)") }
      if entry.deleted { lines.append("- remove this element") }
      return StudioFeedbackPromptBuilder.ElementEdits(
        element: entry.batch.element,
        variantName: entry.variantName,
        changeLines: lines
      )
    }
    guard let prompt = StudioFeedbackPromptBuilder.editsPrompt(artifact: artifact, edits: entries) else { return }
    editState.clear()
    onSendPrompt(prompt, session)
    showNotice("Edits sent to the agent")
  }

  /// Drops the live edits by reloading the page — the served document was
  /// never touched, so a reload is the undo.
  private func discardPendingEdits() {
    editState.clear()
    panelState.reload()
  }

  private func sendFeedback(artifact: StudioArtifact, element: ElementInspectorData, instruction: String) {
    Task { @MainActor in
      let variantName = artifact.kind == .canvas
        ? await resolveVariantName(for: element)
        : nil
      let prompt = StudioFeedbackPromptBuilder.prompt(
        artifact: artifact,
        variantName: variantName,
        element: element,
        instruction: instruction
      )
      inspectState.dismissInput()
      onSendPrompt(prompt, session)
      showNotice("Sent to the agent")
    }
  }

  /// Which artboard the element sits on. Asks the page (authoritative), falling
  /// back to parsing the selector.
  private func resolveVariantName(for element: ElementInspectorData) async -> String? {
    if let webView {
      let selectorLiteral = Self.javaScriptStringLiteral(element.cssSelector)
      let script = "window.__agenthubStudio && window.__agenthubStudio.variantForSelector(\(selectorLiteral))"
      if let result = try? await webView.evaluateJavaScript(script) as? String, !result.isEmpty {
        return result
      }
    }
    return StudioPanelState.variantName(fromSelector: element.cssSelector)
  }

  // MARK: Tweaks

  private func handleTweakPropsChange(_ props: [TweakProp]) {
    tweaksState.updateSchema(props)
    hasDeclaredTweakProps = !props.isEmpty || hasDeclaredTweakProps
    tweaksDefaultsSaveState = .idle
  }

  private func handleTweakValueChange(prop: TweakProp, value: TweakPropValue) {
    tweaksState.updateValue(name: prop.name, value)
    if case .failed = tweaksDefaultsSaveState { tweaksDefaultsSaveState = .idle }
    if let webView {
      TweaksBridge.setProp(name: prop.name, value: value, in: webView)
    }
  }

  private func resetTweakValues() {
    let reset = tweaksState.resetToDefaults()
    tweaksDefaultsSaveState = .idle
    guard let webView else { return }
    for prop in reset {
      TweaksBridge.setProp(name: prop.name, value: prop.value, in: webView)
    }
  }

  private func saveTweakDefaults(for artifact: StudioArtifact) {
    guard tweaksState.hasUnsavedChanges, tweaksDefaultsSaveState != .saving,
          let library = viewModel.studioLibrary
    else { return }
    let values = Dictionary(uniqueKeysWithValues: tweaksState.props
      .filter { $0.value != $0.defaultValue }
      .map { ($0.name, $0.value) })
    let key = viewModel.projectScopeKey(for: session)
    tweaksDefaultsSaveState = .saving
    Task { @MainActor in
      do {
        try await library.saveTweakDefaults(
          artifactId: artifact.id,
          values: values,
          projectKey: key,
          sessionId: session.id,
          aliasPaths: []
        )
        tweaksState.commitCurrentValuesAsDefaults()
        tweaksDefaultsSaveState = .idle
        showNotice("Defaults saved")
      } catch {
        tweaksDefaultsSaveState = .failed(error.localizedDescription)
      }
    }
  }

  /// Ideas / Custom / Delete all: a re-file request into the session. The
  /// spinner clears when the artifact's revision advances, or after a timeout —
  /// the agent may simply never call back.
  private func sendTweaksAgentPrompt(_ prompt: String) {
    guard tweaksAgentState != .working, let selectedArtifact else { return }
    tweaksAgentRevisionBaseline = selectedArtifact.revision
    tweaksAgentState = .working
    tweakGenerationTimer.start()
    onSendPrompt(prompt, session)
    let baseline = selectedArtifact.revision
    let artifactId = selectedArtifact.id
    Task { @MainActor in
      try? await Task.sleep(for: CLISessionsViewModel.rerunTimeout)
      guard tweaksAgentState == .working, tweaksAgentRevisionBaseline == baseline,
            self.selectedArtifact?.id == artifactId
      else { return }
      tweaksAgentRevisionBaseline = nil
      tweakGenerationTimer.stop()
      tweaksAgentState = .failed("The agent didn't re-file the \(selectedArtifact.kind == .canvas ? "canvas" : "artifact") in time.")
    }
  }

  /// Sends the implement request with the *current* variant markup — panel
  /// edits are baked first, so what the agent gets is what the user sees.
  private func promote(artifact: StudioArtifact, variantName: String) async {
    await flushPendingBakeAndWait(artifactId: artifact.id)
    let key = viewModel.projectScopeKey(for: session)
    let current = viewModel.studioLibrary?.artifact(id: artifact.id, projectKey: key) ?? artifact
    guard let prompt = StudioPromotionPromptBuilder.prompt(artifact: current, variantName: variantName) else { return }
    onSendPrompt(prompt, session)
    showNotice("Asked the agent to implement \u{201C}\(variantName)\u{201D}")
  }

  private func deleteSelected() {
    guard let selectedArtifact else { return }
    viewModel.deleteStudioArtifact(id: selectedArtifact.id, in: session)
    panelState.selectedArtifactId = nil
  }

  private func copyLink() {
    guard let servedURL else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(servedURL.absoluteString, forType: .string)
    showNotice("Link copied — valid while AgentHub is running")
  }

  private func exportDocument(_ artifact: StudioArtifact) {
    guard let library = viewModel.studioLibrary else { return }
    let key = viewModel.projectScopeKey(for: session)
    let source = library.documentURL(for: artifact, projectKey: key)
    guard FileManager.default.fileExists(atPath: source.path) else {
      showNotice("Nothing to export yet")
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.html]
    panel.nameFieldStringValue = Self.exportFileName(for: artifact)
    panel.title = "Export Studio Artifact"
    panel.message = "Saves the rendered HTML. It is agent-generated and unreviewed — treat it like any file the agent wrote."
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
      showNotice("Exported")
    } catch {
      panelState.failureMessage = "Export failed: \(error.localizedDescription)"
    }
  }

  private func showNotice(_ text: String) {
    withAnimation { transientNotice = text }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      if transientNotice == text {
        withAnimation { transientNotice = nil }
      }
    }
  }

  private func pickerLabel(for artifact: StudioArtifact) -> String {
    let sharesTitle = artifacts.filter { $0.title == artifact.title }.count > 1
    return sharesTitle ? "\(artifact.title) · rev \(artifact.revision)" : artifact.title
  }

  static func exportFileName(for artifact: StudioArtifact) -> String {
    let base = artifact.title
      .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted)
      .joined()
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: " ", with: "-")
    return (base.isEmpty ? "studio-artifact" : base) + ".html"
  }

  static func javaScriptStringLiteral(_ text: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data()
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
  }
}

// MARK: - StudioWarningsBanner

/// What normalization dropped when the agent filed this artifact. Kept visible
/// so a canvas missing its scripts or an @import is not mistaken for a
/// rendering bug.
private struct StudioWarningsBanner: View {
  let warnings: [String]
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Text(warnings.count == 1 ? "1 note from the agent's markup" : "\(warnings.count) notes from the agent's markup")
            .font(.caption.weight(.medium))
          Spacer()
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
          Text("• \(warning)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.orange.opacity(0.08))
  }
}


private extension Optional {
  func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
    guard let self else { return nil }
    return await transform(self)
  }
}


// MARK: - StudioPageMessageHandler

/// Receives the canvas host page's Implement clicks
/// (`window.webkit.messageHandlers.agentHubStudio`).
final class StudioPageMessageHandler: NSObject, WKScriptMessageHandler {
  static let name = "agentHubStudio"
  var onImplement: ((String) -> Void)?

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == Self.name,
          let body = message.body as? [String: Any],
          body["type"] as? String == "implement",
          let variant = body["variant"] as? String, !variant.isEmpty
    else { return }
    onImplement?(variant)
  }
}
