//
//  SimulatorAnnotationOverlayView.swift
//  AgentHub
//
//  Annotation layer for the live simulator preview. While annotate mode is
//  active, the simulated app's accessibility tree (SimulatorAXInspector) is
//  rendered as element frames over the stream: hovering highlights the element
//  under the cursor, and clicks drop numbered pins bound to that element (with
//  an inline bubble capturing the instruction). When element data is
//  unavailable, pins fall back to positional annotations.
//

import SimulatorPreview
import SwiftUI

/// UI state for one panel's annotation session.
@MainActor
@Observable
final class SimulatorAnnotationModel {
  /// Whether clicks drop pins instead of forwarding touches to the device.
  var isAnnotating = false
  var annotations: [SimulatorAnnotation] = []
  /// A dropped pin awaiting its instruction text (normalized coordinates).
  var pendingNormalizedPoint: CGPoint?
  /// The element under the pending pin, when element data was available.
  var pendingTarget: SimulatorAnnotationTarget?
  /// Device framebuffer size in pixels, from the stream session state.
  var contentPixelSize: CGSize = .zero
  var isSending = false

  /// The frontmost app's accessibility tree (frames in device points).
  var axTree: SimulatorAXElement?
  var isFetchingElements = false
  var hoveredElement: SimulatorAXElement?

  var hasContentSize: Bool {
    contentPixelSize.width > 0 && contentPixelSize.height > 0
  }

  /// The device screen size in points (the accessibility root frame).
  var screenPointSize: CGSize? {
    guard let frame = axTree?.frame, frame.width > 0, frame.height > 0 else { return nil }
    return frame.size
  }

  func remove(id: UUID) {
    annotations.removeAll { $0.id == id }
  }

  func updateText(id: UUID, text: String) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    annotations[index].text = text
  }

  func clearAnnotations() {
    annotations.removeAll()
    clearPending()
  }

  func clearPending() {
    pendingNormalizedPoint = nil
    pendingTarget = nil
  }

  func exitAnnotating() {
    isAnnotating = false
    hoveredElement = nil
    clearPending()
  }

  func reset() {
    exitAnnotating()
    annotations.removeAll()
    axTree = nil
    isFetchingElements = false
    contentPixelSize = .zero
    isSending = false
  }
}

/// Matches the pin color stamped onto outgoing screenshots by
/// `SimulatorScreenshotCapture`.
let simulatorAnnotationPinColor = Color(red: 0.0, green: 0.48, blue: 1.0)
/// Element-frame tint for the inspection overlay.
private let elementFrameColor = Color(nsColor: .systemBlue)

struct SimulatorAnnotationOverlayView: View {
  let model: SimulatorAnnotationModel

  @Environment(\.colorScheme) private var colorScheme

  @State private var draftText = ""
  @FocusState private var isInputFocused: Bool

  private var annotationSurfaceStyle: AnyShapeStyle {
    colorScheme == .light
      ? AnyShapeStyle(.thinMaterial)
      : AnyShapeStyle(.regularMaterial)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        if model.isAnnotating {
          elementFrames(in: geometry.size)

          Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
              switch phase {
              case .active(let location):
                model.hoveredElement = element(at: location, viewSize: geometry.size)
              case .ended:
                model.hoveredElement = nil
              }
            }
            .gesture(
              SpatialTapGesture().onEnded { value in
                handleTap(at: value.location, viewSize: geometry.size)
              }
            )

          hoverHighlight(in: geometry.size)
        }

        pins(in: geometry.size)

        if model.isAnnotating, model.annotations.isEmpty, model.pendingNormalizedPoint == nil {
          dropHint(in: geometry.size)
        }

        if let pending = model.pendingNormalizedPoint,
           let pinPoint = viewPoint(forNormalized: pending, viewSize: geometry.size) {
          SimulatorAnnotationPinBadge(number: model.annotations.count + 1)
            .position(pinPoint)
          inputBubble(near: pinPoint, viewSize: geometry.size)
        }
      }
    }
  }

  // MARK: - Element frames

  @ViewBuilder
  private func elementFrames(in viewSize: CGSize) -> some View {
    if let tree = model.axTree {
      // Skip the root application element — its frame is the whole screen.
      ForEach(Array(tree.children.flatMap { $0.flattened() }.enumerated()), id: \.offset) { _, element in
        if let rect = viewRect(forDeviceFrame: element.frame, viewSize: viewSize),
           rect.width > 1, rect.height > 1 {
          RoundedRectangle(cornerRadius: 3)
            .fill(elementFrameColor.opacity(0.05))
            .overlay(
              RoundedRectangle(cornerRadius: 3)
                .stroke(elementFrameColor.opacity(0.45), lineWidth: 1)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
      }
    }
  }

  @ViewBuilder
  private func hoverHighlight(in viewSize: CGSize) -> some View {
    if let hovered = model.hoveredElement,
       let rect = viewRect(forDeviceFrame: hovered.frame, viewSize: viewSize) {
      RoundedRectangle(cornerRadius: 3)
        .fill(elementFrameColor.opacity(0.16))
        .overlay(
          RoundedRectangle(cornerRadius: 3)
            .stroke(elementFrameColor, lineWidth: 2)
        )
        .frame(width: max(rect.width, 2), height: max(rect.height, 2))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)

      elementChip(for: hovered, frame: rect, viewSize: viewSize)
        .allowsHitTesting(false)
    }
  }

  private func elementChip(for element: SimulatorAXElement, frame: CGRect, viewSize: CGSize) -> some View {
    let size = element.frame.size
    let text = "\(element.summary) · \(Int(size.width))×\(Int(size.height)) pt"
    let chipWidth: CGFloat = min(280, max(120, CGFloat(text.count) * 6.5))
    let x = min(max(frame.midX, chipWidth / 2 + 8), viewSize.width - chipWidth / 2 - 8)
    let above = frame.minY - 16
    let y = above < 14 ? min(frame.maxY + 16, viewSize.height - 14) : above

    return Text(text)
      .font(.caption2.weight(.medium))
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Capsule().fill(annotationSurfaceStyle))
      .overlay(Capsule().stroke(elementFrameColor.opacity(0.5), lineWidth: 1))
      .frame(maxWidth: chipWidth)
      .position(x: x, y: y)
  }

  // MARK: - Pins

  @ViewBuilder
  private func pins(in viewSize: CGSize) -> some View {
    ForEach(Array(model.annotations.enumerated()), id: \.element.id) { index, annotation in
      if let point = viewPoint(
        forNormalized: CGPoint(x: annotation.normalizedX, y: annotation.normalizedY),
        viewSize: viewSize
      ) {
        SimulatorAnnotationPinBadge(number: index + 1)
          .position(point)
          .help(annotation.text)
      }
    }
  }

  private func dropHint(in viewSize: CGSize) -> some View {
    Text(
      model.isFetchingElements
        ? "Reading app elements…"
        : model.axTree == nil
          ? "Click anywhere to drop a pin (element data unavailable)"
          : "Click an element to annotate it"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(annotationSurfaceStyle))
    .position(x: viewSize.width / 2, y: 24)
    .allowsHitTesting(false)
  }

  // MARK: - Input bubble

  private var trimmedDraft: String {
    draftText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func inputBubble(near pinPoint: CGPoint, viewSize: CGSize) -> some View {
    let margin: CGFloat = 8
    let availableWidth = max(1, viewSize.width - margin * 2)
    let bubbleWidth = min(300, availableWidth)
    let halfWidth = bubbleWidth / 2
    let x = min(
      max(pinPoint.x, margin + halfWidth),
      viewSize.width - margin - halfWidth
    )
    let estimatedBubbleHeight: CGFloat = model.pendingTarget == nil ? 46 : 64
    let halfHeight = estimatedBubbleHeight / 2
    let belowY = pinPoint.y + 50
    let aboveY = pinPoint.y - 50
    let y: CGFloat
    if belowY + halfHeight <= viewSize.height - margin {
      y = belowY
    } else if aboveY - halfHeight >= margin {
      y = aboveY
    } else {
      y = min(max(belowY, margin + halfHeight), viewSize.height - margin - halfHeight)
    }

    return VStack(alignment: .leading, spacing: 4) {
      if let target = model.pendingTarget {
        Text(target.summary)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
      }

      HStack(spacing: 8) {
        TextField("Describe the change…", text: $draftText)
          .textFieldStyle(.plain)
          .font(.callout)
          .focused($isInputFocused)
          .onSubmit { commitDraft() }
          .onExitCommand { cancelDraft() }

        Button(action: commitDraft) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title3)
            .foregroundStyle(trimmedDraft.isEmpty ? Color.secondary : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(trimmedDraft.isEmpty)
        .help("Add annotation")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(width: bubbleWidth)
    .background(RoundedRectangle(cornerRadius: 18).fill(annotationSurfaceStyle))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(NSColor.separatorColor), lineWidth: 1))
    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    .position(x: x, y: y)
    .onAppear { isInputFocused = true }
  }

  // MARK: - Actions

  private func handleTap(at location: CGPoint, viewSize: CGSize) {
    guard model.hasContentSize else { return }
    guard let normalized = SimulatorPointMapper.normalizedPoint(
      viewPoint: location,
      contentSize: model.contentPixelSize,
      viewSize: viewSize
    ) else { return }

    // A second click commits a written draft, then starts the next pin —
    // an empty draft just moves the pending pin.
    if model.pendingNormalizedPoint != nil, !trimmedDraft.isEmpty {
      commitDraft()
    }
    model.pendingNormalizedPoint = normalized
    model.pendingTarget = element(at: location, viewSize: viewSize)
      .map { SimulatorAnnotationTarget(element: $0, tree: model.axTree) }
    isInputFocused = true
  }

  private func commitDraft() {
    guard let pending = model.pendingNormalizedPoint else { return }
    let text = trimmedDraft
    guard !text.isEmpty else {
      cancelDraft()
      return
    }
    model.annotations.append(
      SimulatorAnnotation(
        normalizedX: pending.x, normalizedY: pending.y,
        text: text, target: model.pendingTarget)
    )
    draftText = ""
    model.clearPending()
  }

  private func cancelDraft() {
    draftText = ""
    model.clearPending()
  }

  // MARK: - Mapping

  /// The non-root accessibility element under a view-space location.
  private func element(at location: CGPoint, viewSize: CGSize) -> SimulatorAXElement? {
    guard let tree = model.axTree, tree.frame.width > 0, tree.frame.height > 0,
      model.hasContentSize,
      let normalized = SimulatorPointMapper.normalizedPoint(
        viewPoint: location, contentSize: model.contentPixelSize, viewSize: viewSize)
    else { return nil }

    let devicePoint = CGPoint(
      x: normalized.x * tree.frame.width,
      y: normalized.y * tree.frame.height)
    guard let hit = tree.deepestElement(containing: devicePoint), hit != tree else { return nil }
    return hit
  }

  private func viewPoint(forNormalized normalized: CGPoint, viewSize: CGSize) -> CGPoint? {
    guard model.hasContentSize else { return nil }
    return SimulatorPointMapper.viewPoint(
      normalizedX: normalized.x,
      normalizedY: normalized.y,
      contentSize: model.contentPixelSize,
      viewSize: viewSize
    )
  }

  /// Maps a device-point frame (accessibility space) to view space through the
  /// normalized framebuffer mapping.
  private func viewRect(forDeviceFrame frame: CGRect, viewSize: CGSize) -> CGRect? {
    guard let root = model.axTree?.frame, root.width > 0, root.height > 0 else { return nil }
    guard
      let topLeft = viewPoint(
        forNormalized: CGPoint(x: frame.minX / root.width, y: frame.minY / root.height),
        viewSize: viewSize),
      let bottomRight = viewPoint(
        forNormalized: CGPoint(x: frame.maxX / root.width, y: frame.maxY / root.height),
        viewSize: viewSize)
    else { return nil }
    return CGRect(
      x: topLeft.x, y: topLeft.y,
      width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
  }
}

/// Numbered circular pin, visually matching the pins stamped onto the
/// screenshot sent to the agent.
struct SimulatorAnnotationPinBadge: View {
  let number: Int
  var size: CGFloat = 36

  var body: some View {
    Text("\(number)")
      .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Circle().fill(simulatorAnnotationPinColor))
      .overlay(Circle().stroke(.white, lineWidth: 1.5))
      .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
      .accessibilityLabel("Annotation pin \(number)")
  }
}
