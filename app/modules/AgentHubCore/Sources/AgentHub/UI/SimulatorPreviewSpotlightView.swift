//
//  SimulatorPreviewSpotlightView.swift
//  AgentHub
//
//  The Previews tab of the simulator panel. Candidates come from two
//  signals: the file open in the session's editor pane and the files
//  changed this session (watcher + git seed). One candidate renders as a
//  single centered preview; several render as a small grid — e.g. a file
//  open in the editor while the agent changes another shows both.
//
//  Deliberately bounded: discovery fetches metadata only (a runtime symbol
//  scan, cheap at monorepo scale) and at most a handful of previews render
//  at a time, inside the live app's process. Images are shown at their true
//  point size (the host renders at device scale and reports it) — never
//  upscaled, which is what made early versions blurry.
//

import AppKit
import SimulatorPreview
import SwiftUI

struct SimulatorPreviewSpotlightView: View {
  let client: any PreviewHostClientProtocol
  /// Bumped by the hot-reload monitor on every successful injection or
  /// rebuild; re-renders the visible previews.
  let reloadGeneration: Int
  /// Source files edited this session, most recent first.
  var changedFiles: [String] = []
  /// File open in the session's editor pane, if any — its previews are
  /// always included, first.
  var openFileName: String?
  /// True while an injection or fallback rebuild is in flight — rendering
  /// pauses so it can't race the code swap.
  var isReloadInFlight = false
  /// Launches the app with preview support. The owner chooses the fast
  /// relaunch or full build path based on device/app state.
  var onLaunchPreviews: (() -> Void)?
  /// True after AgentHub has launched the app with the preview host inserted.
  /// A transient connection failure then means "still starting", not "not armed".
  var isPreviewHostExpected = false
  /// Device the armed app runs on, when this panel launched it.
  var connectedDeviceName: String?

  /// Upper bound on simultaneously rendered previews.
  private static let maxCandidates = 6

  @State private var previewTypes: [PreviewHostPreviewType] = []
  @State private var isLoading = true
  @State private var loadErrorMessage: String?
  /// Expanded (pinned) preview: takes over the tab and stays visible across
  /// file switches and new changes until minimized.
  @State private var expandedSelection: SimulatorPreviewSelection?
  @Namespace private var previewExpansionNamespace

  private let expansionAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)

  private var manifestLoadID: String {
    "\(reloadGeneration)|\(isPreviewHostExpected)"
  }

  var body: some View {
    Group {
      if let loadErrorMessage {
        unavailableState(message: loadErrorMessage)
      } else if previewTypes.isEmpty && isLoading {
        if isPreviewHostExpected {
          startingState
        } else {
          loadingState
        }
      } else if candidates.isEmpty {
        waitingState
      } else {
        spotlight
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: manifestLoadID) { await loadManifest() }
  }

  // MARK: - Candidates

  /// Open-file previews first, then changed files by recency, deduplicated
  /// and bounded.
  private var candidates: [SimulatorPreviewSelection] {
    var fileNames: [String] = []
    if let openFileName, openFileName.hasSuffix(".swift") {
      fileNames.append(openFileName)
    }
    for file in changedFiles where !fileNames.contains(file) {
      fileNames.append(file)
    }

    var selections: [SimulatorPreviewSelection] = []
    for file in fileNames {
      for type in previewTypes where type.matchesSource(fileNames: [file]) {
        for previewId in type.previewIds {
          let selection = SimulatorPreviewSelection(
            typeName: type.typeName,
            previewId: previewId,
            title: type.cardTitle,
            subtitle: type.moduleName
          )
          if !selections.contains(selection) { selections.append(selection) }
          if selections.count == Self.maxCandidates { return selections }
        }
      }
    }
    return selections
  }

  // MARK: - Spotlight

  @ViewBuilder
  private var spotlight: some View {
    VStack(spacing: 0) {
      if let expandedSelection {
        SimulatorPreviewCanvasView(
          client: client,
          selection: expandedSelection,
          reloadGeneration: reloadGeneration,
          isReloadInFlight: isReloadInFlight,
          isExpanded: true,
          onToggleExpand: collapseExpandedPreview
        )
        .id(expandedSelection.id)
        .matchedGeometryEffect(id: expandedSelection.id, in: previewExpansionNamespace)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
      } else if candidates.count == 1, let single = candidates.first {
        SimulatorPreviewCanvasView(
          client: client,
          selection: single,
          reloadGeneration: reloadGeneration,
          isReloadInFlight: isReloadInFlight,
          onToggleExpand: { expand(single) }
        )
        .id(single.id)
        .matchedGeometryEffect(id: single.id, in: previewExpansionNamespace)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
      } else {
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12)],
            spacing: 12
          ) {
            ForEach(candidates) { candidate in
              SimulatorPreviewCanvasView(
                client: client,
                selection: candidate,
                reloadGeneration: reloadGeneration,
                isReloadInFlight: isReloadInFlight,
                canvasHeight: 240,
                onToggleExpand: { expand(candidate) }
              )
              .id(candidate.id)
              .matchedGeometryEffect(id: candidate.id, in: previewExpansionNamespace)
            }
          }
          .padding(12)
        }
        .transition(.opacity)
      }

      if let connectedDeviceName {
        Text("Previewing the app on \(connectedDeviceName)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.bottom, 6)
      }
    }
    .animation(expansionAnimation, value: expandedSelection)
  }

  private func expand(_ selection: SimulatorPreviewSelection) {
    withAnimation(expansionAnimation) {
      expandedSelection = selection
    }
  }

  private func collapseExpandedPreview() {
    withAnimation(expansionAnimation) {
      expandedSelection = nil
    }
  }

  // MARK: - States

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView()
      Text("Discovering previews…")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var startingState: some View {
    VStack(spacing: 8) {
      ProgressView()
      Text("Starting previews…")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var waitingState: some View {
    ContentUnavailableView {
      Label("Waiting for a Change", systemImage: "clock.arrow.circlepath")
    } description: {
      Text("Open or save a Swift file with a #Preview and it renders here, "
        + "updating live on every hot reload.")
    }
  }

  private func unavailableState(message: String) -> some View {
    ContentUnavailableView {
      Label("Previews Not Running", systemImage: "bolt.slash")
    } description: {
      VStack(spacing: 4) {
        Text(
          "Launch the app with preview support enabled to render SwiftUI previews here.")
        if !message.isEmpty {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    } actions: {
      if let onLaunchPreviews {
        Button("Launch Previews") { onLaunchPreviews() }
          .buttonStyle(.borderedProminent)
      } else {
        Button("Retry") {
          Task { await loadManifest() }
        }
      }
    }
  }

  // MARK: - Loading

  /// Metadata only — no rendering happens until a preview is shown.
  private func loadManifest() async {
    isLoading = true
    loadErrorMessage = nil
    defer { isLoading = false }

    let maxAttempts = isPreviewHostExpected ? 16 : 1
    for attempt in 1...maxAttempts {
      do {
        previewTypes = try await client.listPreviews()
        loadErrorMessage = nil
        return
      } catch PreviewHostClientError.serverUnreachable where isPreviewHostExpected && attempt < maxAttempts {
        try? await Task.sleep(for: .milliseconds(500))
      } catch {
        previewTypes = []
        loadErrorMessage = userFacingLoadErrorMessage(for: error)
        return
      }
    }

    previewTypes = []
    loadErrorMessage = "Preview support did not respond after launch."
  }

  private func userFacingLoadErrorMessage(for error: Error) -> String {
    if (error as? PreviewHostClientError) == .serverUnreachable {
      return isPreviewHostExpected
        ? "Preview support did not respond after launch."
        : ""
    }
    return error.localizedDescription
  }
}

// MARK: - Selection model

struct SimulatorPreviewSelection: Identifiable, Hashable {
  let typeName: String
  let previewId: String
  let title: String
  let subtitle: String?

  var id: String { "\(typeName)/\(previewId)" }
}

// MARK: - Canvas

/// Renders one preview at its true point size — fitted down when space is
/// tight, never scaled up. Holds the previous image while re-rendering,
/// pauses while a reload is in flight, and turns failures into a retry.
struct SimulatorPreviewCanvasView: View {
  let client: any PreviewHostClientProtocol
  let selection: SimulatorPreviewSelection
  let reloadGeneration: Int
  var isReloadInFlight = false
  /// Fixed canvas height for grid cells; nil lets the single spotlight size
  /// to the preview's natural dimensions.
  var canvasHeight: CGFloat?
  /// Pinned full-tab mode: the hover control minimizes instead of expanding.
  var isExpanded = false
  var onToggleExpand: (() -> Void)?

  @Environment(\.displayScale) private var displayScale

  @State private var image: NSImage?
  @State private var renderError: String?
  @State private var isHovering = false

  var body: some View {
    VStack(spacing: 8) {
      canvas
        .frame(height: canvasHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.2))
        )
        .overlay(alignment: .topLeading) {
          if isHovering || isExpanded, onToggleExpand != nil {
            expandButton
              .transition(.scale(scale: 0.92).combined(with: .opacity))
          }
        }
        .onHover { isHovering = $0 }

      VStack(spacing: 1) {
        Text(selection.title)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        if let subtitle = selection.subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .task(id: "\(selection.id)|\(reloadGeneration)|\(isReloadInFlight)") {
      guard !isReloadInFlight else { return }
      await render()
    }
    .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isHovering)
    .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isExpanded)
    .help(renderError ?? selection.title)
  }

  /// Expand pins this preview full-tab (visible across file switches until
  /// minimized); minimize returns to the grid.
  private var expandButton: some View {
    Button {
      onToggleExpand?()
    } label: {
      Image(systemName: isExpanded
        ? "arrow.down.right.and.arrow.up.left"
        : "arrow.up.left.and.arrow.down.right")
        .font(.caption.weight(.semibold))
        .padding(6)
        .background(Circle().fill(.thinMaterial))
    }
    .buttonStyle(.plain)
    .padding(8)
    .help(isExpanded ? "Minimize" : "Expand — stays visible until minimized")
    .accessibilityLabel(isExpanded ? "Minimize preview" : "Expand preview")
  }

  /// Largest lossless display size: one image pixel per screen pixel.
  /// Computed from the bitmap's real pixel dimensions (NSImage.size is
  /// unreliable here — the host's PNGs carry scale as DPI metadata, so
  /// dividing the reported size by the render scale double-shrinks) and the
  /// panel's display scale: a 3x render on a 2x screen can show at 1.5× its
  /// design size before any pixel gets stretched.
  private var maxLosslessSize: CGSize? {
    guard let image else { return nil }
    let pixelWidth = image.representations.first.map { CGFloat($0.pixelsWide) }
      ?? image.size.width
    let pixelHeight = image.representations.first.map { CGFloat($0.pixelsHigh) }
      ?? image.size.height
    let screenScale = max(displayScale, 1)
    return CGSize(
      width: pixelWidth / screenScale, height: pixelHeight / screenScale)
  }

  @ViewBuilder
  private var canvas: some View {
    if let image, let maxSize = maxLosslessSize {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: maxSize.width, maxHeight: maxSize.height)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
          if isReloadInFlight {
            ProgressView()
              .controlSize(.small)
              .padding(10)
          }
        }
    } else if renderError != nil {
      Button {
        Task { await render() }
      } label: {
        VStack(spacing: 6) {
          Image(systemName: "arrow.clockwise")
            .foregroundStyle(.orange)
          Text("Render failed — retry")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.06))
      }
      .buttonStyle(.plain)
    } else {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.06))
    }
  }

  private func render() async {
    do {
      let result = try await client.render(
        typeName: selection.typeName, previewId: selection.previewId)
      if let data = result.imageData, let rendered = NSImage(data: data) {
        image = rendered
        renderError = nil
      } else {
        renderError = result.errorMessage ?? "No image produced"
      }
    } catch {
      renderError = error.localizedDescription
    }
  }
}
